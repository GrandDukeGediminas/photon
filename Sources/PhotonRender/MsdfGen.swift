import CoreGraphics
import Foundation
import simd

/// Multi-channel signed distance field generation, ported from msdfgen (Viktor Chlumský, v1.11-era core) as linked into
/// wallpaper64.exe. The engine's MSDF glyph path (0x1401aefe2–0x1401af853) runs: FreeType outline → msdfgen Shape
/// (move/line/conic/cubic callbacks, 1/64 scale), `Shape::normalize` (inlined loop with the deconverge factor
/// 1.11111·sqrt(2e-6)), `Shape::orientContours` 0x140281900 (ratio 0.5·(sqrt 5 − 1)), `edgeColoringSimple(shape, 3.0)`
/// 0x140283500, `generateDistanceField<OverlappingContourCombiner<MultiDistanceSelector>>` 0x140283d60 and
/// `msdfErrorCorrection` 0x14028a910 with the default config (overlap support, EDGE_PRIORITY, CHECK_DISTANCE_AT_EDGE,
/// min deviation / improve ratio 1.11111).
///
/// Differences from msdfgen: the per-edge `EdgeCache` relevance skip is not used (every edge is evaluated for every
/// sample; the skip is conservative, so results only differ on exact ties), and `convergentCurveOrdering`'s rare
/// "both sides degenerate" tail is reconstructed from the derivative order.
enum MsdfGen {
    /// Builds an msdfgen Shape from a CGPath (glyph outline in pixels, y up; quadCurve/curve elements become
    /// quadratic/cubic segments, closeSubpath closes with a line when the end differs from the start).
    /// Returns width*height*3 floats (RGB), row 0 = bottom row (msdfgen bitmap orientation), values as msdfgen writes
    /// them (not clamped).
    static func generate(path: CGPath, width: Int, height: Int, scale: Double, translate: SIMD2<Double>, range: Double) -> [Float] {
        guard width > 0, height > 0 else { return [] }
        var shape = mgImport(path)
        mgNormalize(&shape)
        mgOrientContours(&shape)
        mgEdgeColoringSimple(&shape, angleThreshold: 3.0, seed: 0)
        let tr = MGTransform(scale: V(scale, scale), translate: translate, range: range)
        let flat = MGShape(shape)
        var sdf = mgGenerateMSDF(flat, width: width, height: height, tr)
        mgErrorCorrection(&sdf, width: width, height: height, flat, tr)
        return sdf
    }
}

// MARK: - Vector helpers (msdfgen Vector2)

private typealias V = SIMD2<Double>
private let DBL_MAX = Double.greatestFiniteMagnitude

@inline(__always) private func mgCross(_ a: V, _ b: V) -> Double { a.x * b.y - a.y * b.x }
@inline(__always) private func mgDot(_ a: V, _ b: V) -> Double { a.x * b.x + a.y * b.y }
@inline(__always) private func vlen(_ a: V) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }
@inline(__always) private func isZero(_ a: V) -> Bool { a.x == 0 && a.y == 0 }
@inline(__always) private func mgMix(_ a: V, _ b: V, _ w: Double) -> V { (1 - w) * a + w * b }
@inline(__always) private func mixD(_ a: Double, _ b: Double, _ w: Double) -> Double { (1 - w) * a + w * b }
/// msdfgen `mgMix(float, float, double)`: computed in double, stored as float.
@inline(__always) private func mixF(_ a: Float, _ b: Float, _ w: Double) -> Float { Float((1 - w) * Double(a) + w * Double(b)) }
@inline(__always) private func nonZeroSign(_ n: Double) -> Double { n > 0 ? 1 : -1 }
@inline(__always) private func mgSign(_ n: Double) -> Int { (0 < n ? 1 : 0) - (n < 0 ? 1 : 0) }
@inline(__always) private func mgMedian(_ a: Float, _ b: Float, _ c: Float) -> Float { max(min(a, b), min(max(a, b), c)) }
@inline(__always) private func mgMedian(_ a: Double, _ b: Double, _ c: Double) -> Double { max(min(a, b), min(max(a, b), c)) }

private func mgNormalize2(_ a: V, allowZero: Bool = false) -> V {
    let l = vlen(a)
    if l == 0 { return V(0, allowZero ? 0 : 1) }
    return V(a.x / l, a.y / l)
}
private func orthonormal(_ a: V, polarity: Bool) -> V {
    let l = vlen(a)
    if l == 0 { return polarity ? V(0, 1) : V(0, -1) }
    return polarity ? V(-a.y / l, a.x / l) : V(a.y / l, -a.x / l)
}
private func orthogonal(_ a: V, polarity: Bool) -> V { polarity ? V(-a.y, a.x) : V(a.y, -a.x) }

private struct SignedDistance {
    var distance: Double
    var dot: Double
    static let none = SignedDistance(distance: -DBL_MAX, dot: 0)
    static func < (a: SignedDistance, b: SignedDistance) -> Bool {
        abs(a.distance) < abs(b.distance) || (abs(a.distance) == abs(b.distance) && a.dot < b.dot)
    }
}

// MARK: - Equation solvers (equation-solver.cpp)

private let TOO_LARGE_RATIO = 1e12

private func solveQuadratic(_ x: inout [Double], _ a: Double, _ b: Double, _ c: Double) -> Int {
    if a == 0 || abs(b) > TOO_LARGE_RATIO * abs(a) {
        if b == 0 { return c == 0 ? -1 : 0 }
        x[0] = -c / b
        return 1
    }
    var dscr = b * b - 4 * a * c
    if dscr > 0 {
        dscr = dscr.squareRoot()
        x[0] = (-b + dscr) / (2 * a)
        x[1] = (-b - dscr) / (2 * a)
        return 2
    } else if dscr == 0 {
        x[0] = -b / (2 * a)
        return 1
    }
    return 0
}

private func solveCubicNormed(_ x: inout [Double], _ a0: Double, _ b: Double, _ c: Double) -> Int {
    var a = a0
    let a2 = a * a
    var q = 1 / 9.0 * (a2 - 3 * b)
    let r = 1 / 54.0 * (a * (2 * a2 - 9 * b) + 27 * c)
    let r2 = r * r
    let q3 = q * q * q
    a *= 1 / 3.0
    if r2 < q3 {
        var t = r / q3.squareRoot()
        if t < -1 { t = -1 }
        if t > 1 { t = 1 }
        t = acos(t)
        q = -2 * q.squareRoot()
        x[0] = q * cos(1 / 3.0 * t) - a
        x[1] = q * cos(1 / 3.0 * (t + 2 * Double.pi)) - a
        x[2] = q * cos(1 / 3.0 * (t - 2 * Double.pi)) - a
        return 3
    } else {
        let u = (r < 0 ? 1.0 : -1.0) * pow(abs(r) + (r2 - q3).squareRoot(), 1 / 3.0)
        let v = u == 0 ? 0 : q / u
        x[0] = (u + v) - a
        if u == v || abs(u - v) < 1e-12 * abs(u + v) {
            x[1] = -0.5 * (u + v) - a
            return 2
        }
        return 1
    }
}

private func solveCubic(_ x: inout [Double], _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Int {
    if a != 0 {
        let bn = b / a
        if abs(bn) < TOO_LARGE_RATIO { return solveCubicNormed(&x, bn, c / a, d / a) }
    }
    return solveQuadratic(&x, b, c, d)
}

// MARK: - Edge segments (edge-segments.cpp)

private let RED = 1, GREEN = 2, YELLOW = 3, BLUE = 4, MAGENTA = 5, CYAN = 6, WHITE = 7

private let CUBIC_SEARCH_STARTS = 4
private let CUBIC_SEARCH_STEPS = 4

private struct Edge {
    /// 1 linear, 2 quadratic, 3 cubic (= msdfgen EDGE_TYPE / control point count − 1).
    var kind: Int
    var p0 = V(0, 0), p1 = V(0, 0), p2 = V(0, 0), p3 = V(0, 0)
    var color = WHITE

    static func linear(_ a: V, _ b: V, _ color: Int = WHITE) -> Edge { Edge(kind: 1, p0: a, p1: b, color: color) }
    static func quadratic(_ a: V, _ b0: V, _ c: V, _ color: Int = WHITE) -> Edge {
        var b = b0
        if b == a || b == c { b = 0.5 * (a + c) }
        return Edge(kind: 2, p0: a, p1: b, p2: c, color: color)
    }
    static func cubic(_ a: V, _ b0: V, _ c0: V, _ d: V, _ color: Int = WHITE) -> Edge {
        var b = b0, c = c0
        if (b == a || b == d) && (c == a || c == d) {
            b = mgMix(a, d, 1 / 3.0)
            c = mgMix(a, d, 2 / 3.0)
        }
        return Edge(kind: 3, p0: a, p1: b, p2: c, p3: d, color: color)
    }

    var controlPoints: [V] {
        switch kind {
        case 1: return [p0, p1]
        case 2: return [p0, p1, p2]
        default: return [p0, p1, p2, p3]
        }
    }

    func point(_ t: Double) -> V {
        switch kind {
        case 1: return mgMix(p0, p1, t)
        case 2: return mgMix(mgMix(p0, p1, t), mgMix(p1, p2, t), t)
        default:
            let p12 = mgMix(p1, p2, t)
            return mgMix(mgMix(mgMix(p0, p1, t), p12, t), mgMix(p12, mgMix(p2, p3, t), t), t)
        }
    }

    func direction(_ t: Double) -> V {
        switch kind {
        case 1: return p1 - p0
        case 2:
            let tangent = mgMix(p1 - p0, p2 - p1, t)
            if isZero(tangent) { return p2 - p0 }
            return tangent
        default:
            let tangent = mgMix(mgMix(p1 - p0, p2 - p1, t), mgMix(p2 - p1, p3 - p2, t), t)
            if isZero(tangent) {
                if t == 0 { return p2 - p0 }
                if t == 1 { return p3 - p1 }
            }
            return tangent
        }
    }

    func signedDistance(_ origin: V, _ param: inout Double) -> SignedDistance {
        switch kind {
        case 1:
            let aq = origin - p0
            let ab = p1 - p0
            param = mgDot(aq, ab) / mgDot(ab, ab)
            let eq = (param > 0.5 ? p1 : p0) - origin
            let endpointDistance = vlen(eq)
            if param > 0 && param < 1 {
                let orthoDistance = mgDot(orthonormal(ab, polarity: false), aq)
                if abs(orthoDistance) < endpointDistance { return SignedDistance(distance: orthoDistance, dot: 0) }
            }
            return SignedDistance(distance: nonZeroSign(mgCross(aq, ab)) * endpointDistance,
                                  dot: abs(mgDot(mgNormalize2(ab), mgNormalize2(eq))))
        case 2:
            let qa = p0 - origin
            let ab = p1 - p0
            let br = p2 - p1 - ab
            let a = mgDot(br, br)
            let b = 3 * mgDot(ab, br)
            let c = 2 * mgDot(ab, ab) + mgDot(qa, br)
            let d = mgDot(qa, ab)
            var t = [Double](repeating: 0, count: 3)
            let solutions = solveCubic(&t, a, b, c, d)

            var epDir = direction(0)
            var minDistance = nonZeroSign(mgCross(epDir, qa)) * vlen(qa)
            param = -mgDot(qa, epDir) / mgDot(epDir, epDir)
            do {
                epDir = direction(1)
                let distance = vlen(p2 - origin)
                if distance < abs(minDistance) {
                    minDistance = nonZeroSign(mgCross(epDir, p2 - origin)) * distance
                    param = mgDot(origin - p1, epDir) / mgDot(epDir, epDir)
                }
            }
            var i = 0
            while i < solutions {
                if t[i] > 0 && t[i] < 1 {
                    let qe = qa + 2 * t[i] * ab + t[i] * t[i] * br
                    let distance = vlen(qe)
                    if distance <= abs(minDistance) {
                        minDistance = nonZeroSign(mgCross(ab + t[i] * br, qe)) * distance
                        param = t[i]
                    }
                }
                i += 1
            }
            if param >= 0 && param <= 1 { return SignedDistance(distance: minDistance, dot: 0) }
            if param < 0.5 { return SignedDistance(distance: minDistance, dot: abs(mgDot(mgNormalize2(direction(0)), mgNormalize2(qa)))) }
            return SignedDistance(distance: minDistance, dot: abs(mgDot(mgNormalize2(direction(1)), mgNormalize2(p2 - origin))))
        default:
            let qa = p0 - origin
            let ab = p1 - p0
            let br = p2 - p1 - ab
            let as_ = (p3 - p2) - (p2 - p1) - br

            var epDir = direction(0)
            var minDistance = nonZeroSign(mgCross(epDir, qa)) * vlen(qa)
            param = -mgDot(qa, epDir) / mgDot(epDir, epDir)
            do {
                epDir = direction(1)
                let distance = vlen(p3 - origin)
                if distance < abs(minDistance) {
                    minDistance = nonZeroSign(mgCross(epDir, p3 - origin)) * distance
                    param = mgDot(epDir - (p3 - origin), epDir) / mgDot(epDir, epDir)
                }
            }
            for i in 0...CUBIC_SEARCH_STARTS {
                var t = Double(i) / Double(CUBIC_SEARCH_STARTS)
                var qe = qa + 3 * t * ab + 3 * t * t * br + t * t * t * as_
                for _ in 0..<CUBIC_SEARCH_STEPS {
                    let d1 = 3 * ab + 6 * t * br + 3 * t * t * as_
                    let d2 = 6 * br + 6 * t * as_
                    t -= mgDot(qe, d1) / (mgDot(d1, d1) + mgDot(qe, d2))
                    if t <= 0 || t >= 1 { break }
                    qe = qa + 3 * t * ab + 3 * t * t * br + t * t * t * as_
                    let distance = vlen(qe)
                    if distance < abs(minDistance) {
                        minDistance = nonZeroSign(mgCross(d1, qe)) * distance
                        param = t
                    }
                }
            }
            if param >= 0 && param <= 1 { return SignedDistance(distance: minDistance, dot: 0) }
            if param < 0.5 { return SignedDistance(distance: minDistance, dot: abs(mgDot(mgNormalize2(direction(0)), mgNormalize2(qa)))) }
            return SignedDistance(distance: minDistance, dot: abs(mgDot(mgNormalize2(direction(1)), mgNormalize2(p3 - origin))))
        }
    }

    func distanceToPerpendicularDistance(_ distance: inout SignedDistance, _ origin: V, _ param: Double) {
        if param < 0 {
            let dir = mgNormalize2(direction(0))
            let aq = origin - point(0)
            let ts = mgDot(aq, dir)
            if ts < 0 {
                let perpendicularDistance = mgCross(aq, dir)
                if abs(perpendicularDistance) <= abs(distance.distance) {
                    distance.distance = perpendicularDistance
                    distance.dot = 0
                }
            }
        } else if param > 1 {
            let dir = mgNormalize2(direction(1))
            let bq = origin - point(1)
            let ts = mgDot(bq, dir)
            if ts > 0 {
                let perpendicularDistance = mgCross(bq, dir)
                if abs(perpendicularDistance) <= abs(distance.distance) {
                    distance.distance = perpendicularDistance
                    distance.dot = 0
                }
            }
        }
    }

    /// Returns (x, dy) pairs, at most 3.
    func scanlineIntersections(_ y: Double) -> [(Double, Int)] {
        switch kind {
        case 1:
            if (y >= p0.y && y < p1.y) || (y >= p1.y && y < p0.y) {
                let param = (y - p0.y) / (p1.y - p0.y)
                return [(mixD(p0.x, p1.x, param), mgSign(p1.y - p0.y))]
            }
            return []
        case 2:
            var x = [Double](repeating: 0, count: 3), dy = [Int](repeating: 0, count: 3)
            var total = 0
            var nextDY = y > p0.y ? 1 : -1
            x[total] = p0.x
            if p0.y == y {
                if p0.y < p1.y || (p0.y == p1.y && p0.y < p2.y) { dy[total] = 1; total += 1 } else { nextDY = 1 }
            }
            do {
                let ab = p1 - p0
                let br = p2 - p1 - ab
                var t = [Double](repeating: 0, count: 3)
                let solutions = solveQuadratic(&t, br.y, 2 * ab.y, p0.y - y)
                if solutions >= 2 && t[0] > t[1] { t.swapAt(0, 1) }
                var i = 0
                while i < solutions && total < 2 {
                    if t[i] >= 0 && t[i] <= 1 {
                        x[total] = p0.x + 2 * t[i] * ab.x + t[i] * t[i] * br.x
                        if Double(nextDY) * (ab.y + t[i] * br.y) >= 0 {
                            dy[total] = nextDY; total += 1
                            nextDY = -nextDY
                        }
                    }
                    i += 1
                }
            }
            if p2.y == y {
                if nextDY > 0 && total > 0 { total -= 1; nextDY = -1 }
                if (p2.y < p1.y || (p2.y == p1.y && p2.y < p0.y)) && total < 2 {
                    x[total] = p2.x
                    if nextDY < 0 { dy[total] = -1; total += 1; nextDY = 1 }
                }
            }
            if nextDY != (y >= p2.y ? 1 : -1) {
                if total > 0 { total -= 1 } else {
                    if abs(p2.y - y) < abs(p0.y - y) { x[total] = p2.x }
                    dy[total] = nextDY; total += 1
                }
            }
            return (0..<total).map { (x[$0], dy[$0]) }
        default:
            var x = [Double](repeating: 0, count: 3), dy = [Int](repeating: 0, count: 3)
            var total = 0
            var nextDY = y > p0.y ? 1 : -1
            x[total] = p0.x
            if p0.y == y {
                if p0.y < p1.y || (p0.y == p1.y && (p0.y < p2.y || (p0.y == p2.y && p0.y < p3.y))) { dy[total] = 1; total += 1 }
                else { nextDY = 1 }
            }
            do {
                let ab = p1 - p0
                let br = p2 - p1 - ab
                let as_ = (p3 - p2) - (p2 - p1) - br
                var t = [Double](repeating: 0, count: 3)
                let solutions = solveCubic(&t, as_.y, 3 * br.y, 3 * ab.y, p0.y - y)
                if solutions >= 2 {
                    if t[0] > t[1] { t.swapAt(0, 1) }
                    if solutions >= 3 && t[1] > t[2] {
                        t.swapAt(1, 2)
                        if t[0] > t[1] { t.swapAt(0, 1) }
                    }
                }
                var i = 0
                while i < solutions && total < 3 {
                    if t[i] >= 0 && t[i] <= 1 {
                        x[total] = p0.x + 3 * t[i] * ab.x + 3 * t[i] * t[i] * br.x + t[i] * t[i] * t[i] * as_.x
                        if Double(nextDY) * (ab.y + 2 * t[i] * br.y + t[i] * t[i] * as_.y) >= 0 {
                            dy[total] = nextDY; total += 1
                            nextDY = -nextDY
                        }
                    }
                    i += 1
                }
            }
            if p3.y == y {
                if nextDY > 0 && total > 0 { total -= 1; nextDY = -1 }
                if (p3.y < p2.y || (p3.y == p2.y && (p3.y < p1.y || (p3.y == p1.y && p3.y < p0.y)))) && total < 3 {
                    x[total] = p3.x
                    if nextDY < 0 { dy[total] = -1; total += 1; nextDY = 1 }
                }
            }
            if nextDY != (y >= p3.y ? 1 : -1) {
                if total > 0 { total -= 1 } else {
                    if abs(p3.y - y) < abs(p0.y - y) { x[total] = p3.x }
                    dy[total] = nextDY; total += 1
                }
            }
            return (0..<total).map { (x[$0], dy[$0]) }
        }
    }

    mutating func reverse() {
        switch kind {
        case 1: swap(&p0, &p1)
        case 2: swap(&p0, &p2)
        default: swap(&p0, &p3); swap(&p1, &p2)
        }
    }

    func splitInThirds() -> (Edge, Edge, Edge) {
        switch kind {
        case 1:
            return (.linear(p0, point(1 / 3.0), color), .linear(point(1 / 3.0), point(2 / 3.0), color), .linear(point(2 / 3.0), p1, color))
        case 2:
            return (.quadratic(p0, mgMix(p0, p1, 1 / 3.0), point(1 / 3.0), color),
                    .quadratic(point(1 / 3.0), mgMix(mgMix(p0, p1, 5 / 9.0), mgMix(p1, p2, 4 / 9.0), 0.5), point(2 / 3.0), color),
                    .quadratic(point(2 / 3.0), mgMix(p1, p2, 2 / 3.0), p2, color))
        default:
            return (.cubic(p0, p0 == p1 ? p0 : mgMix(p0, p1, 1 / 3.0), mgMix(mgMix(p0, p1, 1 / 3.0), mgMix(p1, p2, 1 / 3.0), 1 / 3.0), point(1 / 3.0), color),
                    .cubic(point(1 / 3.0),
                           mgMix(mgMix(mgMix(p0, p1, 1 / 3.0), mgMix(p1, p2, 1 / 3.0), 1 / 3.0), mgMix(mgMix(p1, p2, 1 / 3.0), mgMix(p2, p3, 1 / 3.0), 1 / 3.0), 2 / 3.0),
                           mgMix(mgMix(mgMix(p0, p1, 2 / 3.0), mgMix(p1, p2, 2 / 3.0), 2 / 3.0), mgMix(mgMix(p1, p2, 2 / 3.0), mgMix(p2, p3, 2 / 3.0), 2 / 3.0), 1 / 3.0),
                           point(2 / 3.0), color),
                    .cubic(point(2 / 3.0), mgMix(mgMix(p1, p2, 2 / 3.0), mgMix(p2, p3, 2 / 3.0), 2 / 3.0), p2 == p3 ? p3 : mgMix(p2, p3, 2 / 3.0), p3, color))
        }
    }

    func convertToCubic() -> Edge { .cubic(p0, mgMix(p0, p1, 2 / 3.0), mgMix(p1, p2, 1 / 3.0), p2, color) }
}

// MARK: - Shape (Shape.cpp, Contour.cpp, import-font.cpp)

private typealias Contour = [Edge]

private func mgImport(_ path: CGPath) -> [Contour] {
    // msdfgen's FreeType callbacks (ftMoveTo/ftLineTo/ftConicTo/ftCubicTo); FT_Outline_Decompose closes every contour.
    var contours: [Contour] = []
    var hasContour = false
    var position = V(0, 0), start = V(0, 0)
    func close() {
        if hasContour, position != start { contours[contours.count - 1].append(.linear(position, start)); position = start }
    }
    path.applyWithBlock { el in
        let e = el.pointee
        func pt(_ i: Int) -> V { V(Double(e.points[i].x), Double(e.points[i].y)) }
        switch e.type {
        case .moveToPoint:
            close()
            if !(hasContour && contours[contours.count - 1].isEmpty) { contours.append([]); hasContour = true }
            position = pt(0); start = position
        case .addLineToPoint:
            let end = pt(0)
            if end != position { contours[contours.count - 1].append(.linear(position, end)); position = end }
        case .addQuadCurveToPoint:
            let end = pt(1)
            if end != position { contours[contours.count - 1].append(.quadratic(position, pt(0), end)); position = end }
        case .addCurveToPoint:
            let end = pt(2)
            if end != position || mgCross(pt(0) - end, pt(1) - end) != 0 {
                contours[contours.count - 1].append(.cubic(position, pt(0), pt(1), end)); position = end
            }
        case .closeSubpath:
            close()
        @unknown default: break
        }
    }
    close()
    if let last = contours.last, last.isEmpty { contours.removeLast() }
    return contours
}

private let CORNER_DOT_EPSILON = 0.000001
private let DECONVERGE_OVERSHOOT = 1.11111111111111111

private func simplifyDegenerateCurve(_ cp: inout [V], _ order: inout Int) {
    if order == 3 && (cp[1] == cp[0] || cp[1] == cp[3]) && (cp[2] == cp[0] || cp[2] == cp[3]) {
        cp[1] = cp[3]
        order = 1
    }
    if order == 2 && (cp[1] == cp[0] || cp[1] == cp[2]) {
        cp[1] = cp[2]
        order = 1
    }
    if order == 1 && cp[0] == cp[1] { order = 0 }
}

/// convergent-curve-ordering.cpp. `before` holds the points before the corner (closest last), `after` the corner and
/// the points after it.
private func convergentCurveOrdering(_ before: [V], _ after: [V], _ controlPointsBefore: Int, _ controlPointsAfter: Int) -> Int {
    guard controlPointsBefore > 0 && controlPointsAfter > 0 else { return 0 }
    let corner = after[0]
    func bp(_ i: Int) -> V { before[before.count - i] } // corner − i
    var a1 = V(0, 0), a2 = V(0, 0), a3 = V(0, 0), b1 = V(0, 0), b2 = V(0, 0), b3 = V(0, 0)
    a1 = bp(1) - corner
    b1 = after[1] - corner
    if controlPointsBefore >= 2 { a2 = bp(2) - bp(1) - a1 }
    if controlPointsAfter >= 2 { b2 = after[2] - after[1] - b1 }
    if controlPointsBefore >= 3 {
        a3 = bp(3) - bp(2) - (bp(2) - bp(1)) - a2
        a2 *= 3
    }
    if controlPointsAfter >= 3 {
        b3 = after[3] - after[2] - (after[2] - after[1]) - b2
        b2 *= 3
    }
    a1 *= Double(controlPointsBefore)
    b1 *= Double(controlPointsAfter)
    if !isZero(a1) && !isZero(b1) {
        let as_ = vlen(a1), bs = vlen(b1)
        var d = as_ * mgCross(a1, b2) + bs * mgCross(a2, b1)
        if d != 0 { return mgSign(d) }
        d = as_ * as_ * mgCross(a1, b3) + as_ * bs * mgCross(a2, b2) + bs * bs * mgCross(a3, b1)
        if d != 0 { return mgSign(d) }
        d = as_ * mgCross(a2, b3) + bs * mgCross(a3, b2)
        if d != 0 { return mgSign(d) }
        return mgSign(mgCross(a3, b3))
    }
    var s = 1
    if !isZero(a1) {
        b1 = a1
        a1 = b2; b2 = a2; a2 = a1
        a1 = b3; b3 = a3; a3 = a1
        s = -1
    }
    if !isZero(b1) {
        var d = mgCross(a3, b1)
        if d != 0 { return s * mgSign(d) }
        d = mgCross(a2, b2)
        if d != 0 { return s * mgSign(d) }
        d = mgCross(a3, b2)
        if d != 0 { return s * mgSign(d) }
        d = mgCross(a2, b3)
        if d != 0 { return s * mgSign(d) }
        return s * mgSign(mgCross(a3, b3))
    }
    // Both sides degenerate (reconstructed): lowest non-vanishing cross term.
    var d = mgCross(a2, b2)
    if d != 0 { return mgSign(d) }
    d = mgCross(a2, b3) + mgCross(a3, b2)
    if d != 0 { return mgSign(d) }
    return mgSign(mgCross(a3, b3))
}

private func convergentCurveOrdering(_ a: Edge, _ b: Edge) -> Int {
    var aOrder = a.kind, bOrder = b.kind
    var aCp = a.controlPoints, bCp = b.controlPoints
    if aCp[aOrder] != bCp[0] { return 0 }
    simplifyDegenerateCurve(&aCp, &aOrder)
    simplifyDegenerateCurve(&bCp, &bOrder)
    return convergentCurveOrdering(Array(aCp[0..<aOrder]), bCp, aOrder, bOrder)
}

private func deconvergeEdge(_ e: inout Edge, _ param: Int, _ vector: V) {
    if e.kind == 2 { e = e.convertToCubic() }
    if e.kind == 3 {
        if param == 0 { e.p1 += vlen(e.p1 - e.p0) * vector }
        else { e.p2 += vlen(e.p2 - e.p3) * vector }
    }
}

private func mgNormalize(_ shape: inout [Contour]) {
    for ci in shape.indices {
        if shape[ci].count == 1 {
            let (a, b, c) = shape[ci][0].splitInThirds()
            shape[ci] = [a, b, c]
        } else if !shape[ci].isEmpty {
            var prev = shape[ci].count - 1
            for cur in shape[ci].indices {
                let prevDir = mgNormalize2(shape[ci][prev].direction(1))
                let curDir = mgNormalize2(shape[ci][cur].direction(0))
                if mgDot(prevDir, curDir) < CORNER_DOT_EPSILON - 1 {
                    let factor = DECONVERGE_OVERSHOOT * (1 - (CORNER_DOT_EPSILON - 1) * (CORNER_DOT_EPSILON - 1)).squareRoot() / (CORNER_DOT_EPSILON - 1)
                    var axis = factor * mgNormalize2(curDir - prevDir)
                    if convergentCurveOrdering(shape[ci][prev], shape[ci][cur]) < 0 { axis = -axis }
                    deconvergeEdge(&shape[ci][prev], 1, orthogonal(axis, polarity: true))
                    deconvergeEdge(&shape[ci][cur], 0, orthogonal(axis, polarity: false))
                }
                prev = cur
            }
        }
    }
}

private func mgOrientContours(_ shape: inout [Contour]) {
    let ratio = 0.5 * (5.0.squareRoot() - 1)
    var orientations = [Int](repeating: 0, count: shape.count)
    var intersections: [(x: Double, direction: Int, contour: Int)] = []
    for i in shape.indices where orientations[i] == 0 && !shape[i].isEmpty {
        let y0 = shape[i][0].point(0).y
        var y1 = y0
        var k = 0
        while k < shape[i].count && y0 == y1 { y1 = shape[i][k].point(1).y; k += 1 }
        k = 0
        while k < shape[i].count && y0 == y1 { y1 = shape[i][k].point(ratio).y; k += 1 }
        let y = mixD(y0, y1, ratio)
        for j in shape.indices {
            for e in shape[j] {
                for (x, dy) in e.scanlineIntersections(y) { intersections.append((x, dy, j)) }
            }
        }
        if !intersections.isEmpty {
            intersections.sort { $0.x < $1.x }
            for j in 1..<max(intersections.count, 1) where intersections[j].x == intersections[j - 1].x {
                intersections[j].direction = 0
                intersections[j - 1].direction = 0
            }
            for j in intersections.indices where intersections[j].direction != 0 {
                orientations[intersections[j].contour] += 2 * ((j & 1) ^ (intersections[j].direction > 0 ? 1 : 0)) - 1
            }
            intersections.removeAll(keepingCapacity: true)
        }
    }
    for i in shape.indices where orientations[i] < 0 {
        shape[i].reverse()
        for k in shape[i].indices { shape[i][k].reverse() }
    }
}

private func contourWinding(_ c: Contour) -> Int {
    if c.isEmpty { return 0 }
    func shoelace(_ a: V, _ b: V) -> Double { (b.x - a.x) * (a.y + b.y) }
    var total = 0.0
    if c.count == 1 {
        let a = c[0].point(0), b = c[0].point(1 / 3.0), cc = c[0].point(2 / 3.0)
        total += shoelace(a, b); total += shoelace(b, cc); total += shoelace(cc, a)
    } else if c.count == 2 {
        let a = c[0].point(0), b = c[0].point(0.5), cc = c[1].point(0), d = c[1].point(0.5)
        total += shoelace(a, b); total += shoelace(b, cc); total += shoelace(cc, d); total += shoelace(d, a)
    } else {
        var prev = c[c.count - 1].point(0)
        for e in c { let cur = e.point(0); total += shoelace(prev, cur); prev = cur }
    }
    return mgSign(total)
}

// MARK: - Edge colouring (edge-coloring.cpp, edgeColoringSimple)

private func isCorner(_ aDir: V, _ bDir: V, _ crossThreshold: Double) -> Bool {
    mgDot(aDir, bDir) <= 0 || abs(mgCross(aDir, bDir)) > crossThreshold
}
private func seedExtract2(_ seed: inout UInt64) -> Int { let v = Int(seed & 1); seed >>= 1; return v }
private func seedExtract3(_ seed: inout UInt64) -> Int { let v = Int(seed % 3); seed /= 3; return v }
private func initColor(_ seed: inout UInt64) -> Int { [CYAN, MAGENTA, YELLOW][seedExtract3(&seed)] }
private func switchColor(_ color: inout Int, _ seed: inout UInt64) {
    let shifted = color << (1 + seedExtract2(&seed))
    color = (shifted | shifted >> 3) & WHITE
}
private func switchColor(_ color: inout Int, _ seed: inout UInt64, _ banned: Int) {
    let combined = color & banned
    if combined == RED || combined == GREEN || combined == BLUE { color = combined ^ WHITE } else { switchColor(&color, &seed) }
}
private func symmetricalTrichotomy(_ position: Int, _ n: Int) -> Int {
    Int(3 + 2.875 * Double(position) / Double(n - 1) - 1.4375 + 0.5) - 3
}

private func mgEdgeColoringSimple(_ shape: inout [Contour], angleThreshold: Double, seed seed0: UInt64) {
    var seed = seed0
    let crossThreshold = sin(angleThreshold)
    var color = initColor(&seed)
    for ci in shape.indices where !shape[ci].isEmpty {
        var corners: [Int] = []
        var prevDirection = shape[ci][shape[ci].count - 1].direction(1)
        for (index, e) in shape[ci].enumerated() {
            if isCorner(mgNormalize2(prevDirection), mgNormalize2(e.direction(0)), crossThreshold) { corners.append(index) }
            prevDirection = e.direction(1)
        }
        if corners.isEmpty {
            switchColor(&color, &seed)
            for k in shape[ci].indices { shape[ci][k].color = color }
        } else if corners.count == 1 {
            var colors = [0, WHITE, 0]
            switchColor(&color, &seed)
            colors[0] = color
            switchColor(&color, &seed)
            colors[2] = color
            let corner = corners[0]
            let m = shape[ci].count
            if m >= 3 {
                for i in 0..<m { shape[ci][(corner + i) % m].color = colors[1 + symmetricalTrichotomy(i, m)] }
            } else if m >= 1 {
                var parts = [Edge?](repeating: nil, count: 7)
                let s0 = shape[ci][0].splitInThirds()
                parts[0 + 3 * corner] = s0.0; parts[1 + 3 * corner] = s0.1; parts[2 + 3 * corner] = s0.2
                if m >= 2 {
                    let s1 = shape[ci][1].splitInThirds()
                    parts[3 - 3 * corner] = s1.0; parts[4 - 3 * corner] = s1.1; parts[5 - 3 * corner] = s1.2
                    parts[0]!.color = colors[0]; parts[1]!.color = colors[0]
                    parts[2]!.color = colors[1]; parts[3]!.color = colors[1]
                    parts[4]!.color = colors[2]; parts[5]!.color = colors[2]
                } else {
                    parts[0]!.color = colors[0]
                    parts[1]!.color = colors[1]
                    parts[2]!.color = colors[2]
                }
                var out: Contour = []
                var i = 0
                while let p = parts[i] { out.append(p); i += 1 }
                shape[ci] = out
            }
        } else {
            let cornerCount = corners.count
            var spline = 0
            let start = corners[0]
            let m = shape[ci].count
            switchColor(&color, &seed)
            let initialColor = color
            for i in 0..<m {
                let index = (start + i) % m
                if spline + 1 < cornerCount && corners[spline + 1] == index {
                    spline += 1
                    switchColor(&color, &seed, spline == cornerCount - 1 ? initialColor : 0)
                }
                shape[ci][index].color = color
            }
        }
    }
}

// MARK: - Distance finding (edge-selectors.cpp, contour-combiners.cpp, ShapeDistanceFinder.hpp)

private struct MGShape {
    var edges: [Edge] = []
    var ranges: [Range<Int>] = []
    var windings: [Int] = []
    init(_ contours: [Contour]) {
        for c in contours {
            let s = edges.count
            edges += c
            ranges.append(s..<edges.count)
            windings.append(contourWinding(c))
        }
    }
}

private struct MGTransform {
    var scale: V
    var translate: V
    var range: Double
    func unproject(_ c: V) -> V { c / scale - translate }
    func project(_ c: V) -> V { (c + translate) * scale }
    func unprojectVector(_ v: V) -> V { v / scale }
    /// DistanceMapping(Range(range)): scale 1/(upper − lower), translate −lower.
    func map(_ d: Double) -> Double { (1 / (0.5 * range - (-0.5 * range))) * (d + (-(-0.5 * range))) }
    var mapDelta1: Double { 1 / (0.5 * range - (-0.5 * range)) }
}

private let DISTANCE_DELTA_FACTOR = 1.001

private func getPerpendicularDistance(_ distance: inout Double, _ ep: V, _ edgeDir: V) -> Bool {
    let ts = mgDot(ep, edgeDir)
    if ts > 0 {
        let perpendicularDistance = mgCross(ep, edgeDir)
        if abs(perpendicularDistance) < abs(distance) {
            distance = perpendicularDistance
            return true
        }
    }
    return false
}

private struct PerpBase {
    var minTrue = SignedDistance.none
    var minNeg = -DBL_MAX
    var minPos = DBL_MAX
    var nearEdge = -1
    var nearParam = 0.0

    mutating func reset(_ delta: Double) {
        minTrue.distance += nonZeroSign(minTrue.distance) * delta
        minNeg = -abs(minTrue.distance)
        minPos = abs(minTrue.distance)
        nearEdge = -1
        nearParam = 0
    }
    mutating func addTrue(_ e: Int, _ d: SignedDistance, _ param: Double) {
        if d < minTrue { minTrue = d; nearEdge = e; nearParam = param }
    }
    mutating func addPerp(_ d: Double) {
        if d <= 0 && d > minNeg { minNeg = d }
        if d >= 0 && d < minPos { minPos = d }
    }
    mutating func merge(_ o: PerpBase) {
        if o.minTrue < minTrue { minTrue = o.minTrue; nearEdge = o.nearEdge; nearParam = o.nearParam }
        if o.minNeg > minNeg { minNeg = o.minNeg }
        if o.minPos < minPos { minPos = o.minPos }
    }
    func compute(_ p: V, _ edges: [Edge]) -> Double {
        var minDistance = minTrue.distance < 0 ? minNeg : minPos
        if nearEdge >= 0 {
            var d = minTrue
            edges[nearEdge].distanceToPerpendicularDistance(&d, p, nearParam)
            if abs(d.distance) < abs(minDistance) { minDistance = d.distance }
        }
        return minDistance
    }
}

private protocol EdgeSelector {
    associatedtype Dist
    init()
    mutating func reset(_ p: V)
    mutating func addEdge(_ prev: Edge, _ edge: Edge, _ index: Int, _ next: Edge)
    mutating func merge(_ o: Self)
    func distance(_ edges: [Edge]) -> Dist
    static func resolve(_ d: Dist) -> Double
    static var initial: Dist { get }
}

/// Geometry shared by the perpendicular selectors' addEdge: the true distance and the two end perpendicular distances.
private func edgeTerms(_ p: V, _ prev: Edge, _ edge: Edge, _ next: Edge) -> (SignedDistance, Double, Double?, Double?) {
    var param = 0.0
    let distance = edge.signedDistance(p, &param)
    let ap = p - edge.point(0)
    let bp = p - edge.point(1)
    let aDir = mgNormalize2(edge.direction(0), allowZero: true)
    let bDir = mgNormalize2(edge.direction(1), allowZero: true)
    let prevDir = mgNormalize2(prev.direction(1), allowZero: true)
    let nextDir = mgNormalize2(next.direction(0), allowZero: true)
    let add = mgDot(ap, mgNormalize2(prevDir + aDir, allowZero: true))
    let bdd = -mgDot(bp, mgNormalize2(bDir + nextDir, allowZero: true))
    var aPerp: Double?, bPerp: Double?
    if add > 0 {
        var pd = distance.distance
        if getPerpendicularDistance(&pd, ap, -aDir) { aPerp = -pd }
    }
    if bdd > 0 {
        var pd = distance.distance
        if getPerpendicularDistance(&pd, bp, bDir) { bPerp = pd }
    }
    return (distance, param, aPerp, bPerp)
}

private struct PerpSelector: EdgeSelector {
    var base = PerpBase()
    var p = V(0, 0)
    init() {}
    mutating func reset(_ p: V) {
        let delta = DISTANCE_DELTA_FACTOR * vlen(p - self.p)
        base.reset(delta)
        self.p = p
    }
    mutating func addEdge(_ prev: Edge, _ edge: Edge, _ index: Int, _ next: Edge) {
        let (d, param, a, b) = edgeTerms(p, prev, edge, next)
        base.addTrue(index, d, param)
        if let a { base.addPerp(a) }
        if let b { base.addPerp(b) }
    }
    mutating func merge(_ o: PerpSelector) { base.merge(o.base) }
    func distance(_ edges: [Edge]) -> Double { base.compute(p, edges) }
    static func resolve(_ d: Double) -> Double { d }
    static var initial: Double { -DBL_MAX }
}

private struct MultiSelector: EdgeSelector {
    var r = PerpBase(), g = PerpBase(), b = PerpBase()
    var p = V(0, 0)
    init() {}
    mutating func reset(_ p: V) {
        let delta = DISTANCE_DELTA_FACTOR * vlen(p - self.p)
        r.reset(delta); g.reset(delta); b.reset(delta)
        self.p = p
    }
    mutating func addEdge(_ prev: Edge, _ edge: Edge, _ index: Int, _ next: Edge) {
        let (d, param, a, bb) = edgeTerms(p, prev, edge, next)
        let c = edge.color
        if c & RED != 0 { r.addTrue(index, d, param) }
        if c & GREEN != 0 { g.addTrue(index, d, param) }
        if c & BLUE != 0 { b.addTrue(index, d, param) }
        if let a {
            if c & RED != 0 { r.addPerp(a) }
            if c & GREEN != 0 { g.addPerp(a) }
            if c & BLUE != 0 { b.addPerp(a) }
        }
        if let bb {
            if c & RED != 0 { r.addPerp(bb) }
            if c & GREEN != 0 { g.addPerp(bb) }
            if c & BLUE != 0 { b.addPerp(bb) }
        }
    }
    mutating func merge(_ o: MultiSelector) { r.merge(o.r); g.merge(o.g); b.merge(o.b) }
    func distance(_ edges: [Edge]) -> SIMD3<Double> { SIMD3(r.compute(p, edges), g.compute(p, edges), b.compute(p, edges)) }
    static func resolve(_ d: SIMD3<Double>) -> Double { mgMedian(d.x, d.y, d.z) }
    static var initial: SIMD3<Double> { SIMD3(-DBL_MAX, -DBL_MAX, -DBL_MAX) }
}

/// ShapeDistanceFinder<OverlappingContourCombiner<S>>. Keeps per-contour selector state between queries, as msdfgen does.
private struct DistanceFinder<S: EdgeSelector> {
    let shape: MGShape
    var selectors: [S]
    var p = V(0, 0)
    init(_ shape: MGShape) {
        self.shape = shape
        selectors = Array(repeating: S(), count: shape.ranges.count)
    }

    mutating func distance(_ origin: V) -> S.Dist {
        p = origin
        for i in selectors.indices { selectors[i].reset(origin) }
        let edges = shape.edges
        for (ci, r) in shape.ranges.enumerated() where !r.isEmpty {
            var prevI = r.count >= 2 ? r.upperBound - 2 : r.lowerBound
            var curI = r.upperBound - 1
            for nextI in r {
                selectors[ci].addEdge(edges[prevI], edges[curI], curI, edges[nextI])
                prevI = curI
                curI = nextI
            }
        }
        return combine()
    }

    /// OverlappingContourCombiner::distance.
    func combine() -> S.Dist {
        let edges = shape.edges
        let contourCount = selectors.count
        var shapeSel = S(), innerSel = S(), outerSel = S()
        shapeSel.reset(p); innerSel.reset(p); outerSel.reset(p)
        for i in 0..<contourCount {
            let edgeDistance = selectors[i].distance(edges)
            shapeSel.merge(selectors[i])
            if shape.windings[i] > 0 && S.resolve(edgeDistance) >= 0 { innerSel.merge(selectors[i]) }
            if shape.windings[i] < 0 && S.resolve(edgeDistance) <= 0 { outerSel.merge(selectors[i]) }
        }
        let shapeDistance = shapeSel.distance(edges)
        let innerDistance = innerSel.distance(edges)
        let outerDistance = outerSel.distance(edges)
        let innerScalar = S.resolve(innerDistance)
        let outerScalar = S.resolve(outerDistance)
        var distance = S.initial
        var winding = 0
        if innerScalar >= 0 && abs(innerScalar) <= abs(outerScalar) {
            distance = innerDistance
            winding = 1
            for i in 0..<contourCount where shape.windings[i] > 0 {
                let cd = selectors[i].distance(edges)
                if abs(S.resolve(cd)) < abs(outerScalar) && S.resolve(cd) > S.resolve(distance) { distance = cd }
            }
        } else if outerScalar <= 0 && abs(outerScalar) < abs(innerScalar) {
            distance = outerDistance
            winding = -1
            for i in 0..<contourCount where shape.windings[i] < 0 {
                let cd = selectors[i].distance(edges)
                if abs(S.resolve(cd)) < abs(innerScalar) && S.resolve(cd) < S.resolve(distance) { distance = cd }
            }
        } else {
            return shapeDistance
        }
        for i in 0..<contourCount where shape.windings[i] != winding {
            let cd = selectors[i].distance(edges)
            if S.resolve(cd) * S.resolve(distance) >= 0 && abs(S.resolve(cd)) < abs(S.resolve(distance)) { distance = cd }
        }
        if S.resolve(distance) == S.resolve(shapeDistance) { distance = shapeDistance }
        return distance
    }
}

/// generateDistanceField<OverlappingContourCombiner<MultiDistanceSelector>> (serpentine rows, inverseYAxis false).
private func mgGenerateMSDF(_ shape: MGShape, width: Int, height: Int, _ tr: MGTransform) -> [Float] {
    var out = [Float](repeating: 0, count: width * height * 3)
    var finder = DistanceFinder<MultiSelector>(shape)
    var rightToLeft = false
    for y in 0..<height {
        for col in 0..<width {
            let x = rightToLeft ? width - col - 1 : col
            let p = tr.unproject(V(Double(x) + 0.5, Double(y) + 0.5))
            let d = finder.distance(p)
            let o = (y * width + x) * 3
            out[o] = Float(tr.map(d.x))
            out[o + 1] = Float(tr.map(d.y))
            out[o + 2] = Float(tr.map(d.z))
        }
        rightToLeft.toggle()
    }
    return out
}

// MARK: - Error correction (MSDFErrorCorrection.cpp, msdf-error-correction.cpp)

private let ARTIFACT_T_EPSILON = 0.01
private let PROTECTION_RADIUS_TOLERANCE = 1.001
private let CLASSIFIER_FLAG_CANDIDATE = 1
private let CLASSIFIER_FLAG_ARTIFACT = 2
private let STENCIL_ERROR: UInt8 = 1
private let STENCIL_PROTECTED: UInt8 = 2
private let MIN_DEVIATION_RATIO = 1.11111111111111111
private let MIN_IMPROVE_RATIO = 1.11111111111111111

private struct SDFView {
    var px: [Float]
    let w: Int, h: Int
    @inline(__always) func at(_ x: Int, _ y: Int) -> SIMD3<Float> {
        let o = (y * w + x) * 3
        return SIMD3(px[o], px[o + 1], px[o + 2])
    }
}

@inline(__always) private func med(_ v: SIMD3<Float>) -> Float { mgMedian(v.x, v.y, v.z) }

private func edgeBetweenTexelsChannel(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ ch: Int) -> Bool {
    let t = (Double(a[ch]) - 0.5) / Double(a[ch] - b[ch])
    if t > 0 && t < 1 {
        let c = SIMD3<Float>(mixF(a.x, b.x, t), mixF(a.y, b.y, t), mixF(a.z, b.z, t))
        return med(c) == c[ch]
    }
    return false
}
private func edgeBetweenTexels(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Int {
    (edgeBetweenTexelsChannel(a, b, 0) ? RED : 0) + (edgeBetweenTexelsChannel(a, b, 1) ? GREEN : 0) + (edgeBetweenTexelsChannel(a, b, 2) ? BLUE : 0)
}
private func protectExtremeChannels(_ s: inout UInt8, _ msd: SIMD3<Float>, _ m: Float, _ mask: Int) {
    if (mask & RED != 0 && msd.x != m) || (mask & GREEN != 0 && msd.y != m) || (mask & BLUE != 0 && msd.z != m) {
        s |= STENCIL_PROTECTED
    }
}

private func interpolatedMedian(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Double) -> Float {
    mgMedian(mixF(a.x, b.x, t), mixF(a.y, b.y, t), mixF(a.z, b.z, t))
}
private func interpolatedMedian(_ a: SIMD3<Float>, _ l: SIMD3<Float>, _ q: SIMD3<Float>, _ t: Double) -> Float {
    Float(mgMedian(t * (t * Double(q.x) + Double(l.x)) + Double(a.x),
                 t * (t * Double(q.y) + Double(l.y)) + Double(a.y),
                 t * (t * Double(q.z) + Double(l.z)) + Double(a.z)))
}

/// The classifier context needed by ShapeDistanceChecker::ArtifactClassifier::evaluate.
private final class ShapeChecker {
    var finder: DistanceFinder<PerpSelector>
    let sdf: SDFView
    let tr: MGTransform
    let texelSize: V
    var shapeCoord = V(0, 0), sdfCoord = V(0, 0)
    var msd = SIMD3<Float>(0, 0, 0)
    var protectedFlag = false
    init(_ sdf: SDFView, _ shape: MGShape, _ tr: MGTransform) {
        finder = DistanceFinder<PerpSelector>(shape)
        self.sdf = sdf
        self.tr = tr
        texelSize = tr.unprojectVector(V(1, 1))
    }
}

private struct Classifier {
    let span: Double
    let protectedFlag: Bool
    let checker: ShapeChecker?
    let direction: V

    func rangeTest(_ at: Double, _ bt: Double, _ xt: Double, _ am: Float, _ bm: Float, _ xm: Float) -> Int {
        if (am > 0.5 && bm > 0.5 && xm <= 0.5) || (am < 0.5 && bm < 0.5 && xm >= 0.5) || (!protectedFlag && mgMedian(am, bm, xm) != xm) {
            let axSpan = (xt - at) * span, bxSpan = (bt - xt) * span
            let x = Double(xm), a = Double(am), b = Double(bm)
            if !(x >= a - axSpan && x <= a + axSpan && x >= b - bxSpan && x <= b + bxSpan) {
                return CLASSIFIER_FLAG_CANDIDATE | CLASSIFIER_FLAG_ARTIFACT
            }
            return CLASSIFIER_FLAG_CANDIDATE
        }
        return 0
    }

    func evaluate(_ t: Double, _ m: Float, _ flags: Int) -> Bool {
        guard let parent = checker else { return flags & CLASSIFIER_FLAG_ARTIFACT != 0 }
        if flags & CLASSIFIER_FLAG_CANDIDATE != 0 {
            if flags & CLASSIFIER_FLAG_ARTIFACT != 0 { return true }
            let tVector = t * direction
            let oldMSD = bilinear(parent.sdf, parent.sdfCoord + tVector)
            let aWeight = (1 - abs(tVector.x)) * (1 - abs(tVector.y))
            let aPSD = med(parent.msd)
            let newMSD = SIMD3<Float>(Float(Double(oldMSD.x) + aWeight * Double(aPSD - parent.msd.x)),
                                      Float(Double(oldMSD.y) + aWeight * Double(aPSD - parent.msd.y)),
                                      Float(Double(oldMSD.z) + aWeight * Double(aPSD - parent.msd.z)))
            let oldPSD = med(oldMSD)
            let newPSD = med(newMSD)
            let refPSD = Float(parent.tr.map(parent.finder.distance(parent.shapeCoord + tVector * parent.texelSize)))
            return MIN_IMPROVE_RATIO * Double(abs(newPSD - refPSD)) < Double(abs(oldPSD - refPSD))
        }
        return false
    }
}

private func bilinear(_ bm: SDFView, _ pos0: V) -> SIMD3<Float> {
    let pos = pos0 - 0.5
    var l = Int(floor(pos.x)), b = Int(floor(pos.y))
    var r = l + 1, t = b + 1
    let lr = pos.x - Double(l), bt = pos.y - Double(b)
    func clampI(_ n: Int, _ m: Int) -> Int { n >= 0 && n <= m ? n : n > 0 ? m : 0 }
    l = clampI(l, bm.w - 1); r = clampI(r, bm.w - 1)
    b = clampI(b, bm.h - 1); t = clampI(t, bm.h - 1)
    let lb = bm.at(l, b), rb = bm.at(r, b), lt = bm.at(l, t), rt = bm.at(r, t)
    var out = SIMD3<Float>(0, 0, 0)
    for i in 0..<3 { out[i] = mixF(mixF(lb[i], rb[i], lr), mixF(lt[i], rt[i], lr), bt) }
    return out
}

private func hasLinearArtifactInner(_ c: Classifier, _ am: Float, _ bm: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ dA: Float, _ dB: Float) -> Bool {
    let t = Double(dA) / Double(dA - dB)
    if t > ARTIFACT_T_EPSILON && t < 1 - ARTIFACT_T_EPSILON {
        let xm = interpolatedMedian(a, b, t)
        return c.evaluate(t, xm, c.rangeTest(0, 1, t, am, bm, xm))
    }
    return false
}

private func hasDiagonalArtifactInner(_ c: Classifier, _ am: Float, _ dm: Float, _ a: SIMD3<Float>, _ l: SIMD3<Float>, _ q: SIMD3<Float>,
                                      _ dA: Float, _ dBC: Float, _ dD: Float, _ tEx0: Double, _ tEx1: Double) -> Bool {
    var t = [Double](repeating: 0, count: 3)
    let solutions = solveQuadratic(&t, Double(dD - dBC + dA), Double(dBC - dA - dA), Double(dA))
    var i = 0
    while i < solutions {
        if t[i] > ARTIFACT_T_EPSILON && t[i] < 1 - ARTIFACT_T_EPSILON {
            let xm = interpolatedMedian(a, l, q, t[i])
            var rangeFlags = c.rangeTest(0, 1, t[i], am, dm, xm)
            for tEx in [tEx0, tEx1] where tEx > 0 && tEx < 1 {
                var tEnd = [0.0, 1.0]
                var em: [Float] = [am, dm]
                let k = tEx > t[i] ? 1 : 0
                tEnd[k] = tEx
                em[k] = interpolatedMedian(a, l, q, tEx)
                rangeFlags |= c.rangeTest(tEnd[0], tEnd[1], t[i], em[0], em[1], xm)
            }
            if c.evaluate(t[i], xm, rangeFlags) { return true }
        }
        i += 1
    }
    return false
}

private func hasLinearArtifact(_ c: Classifier, _ am: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
    let bm = med(b)
    return abs(am - 0.5) >= abs(bm - 0.5) && (
        hasLinearArtifactInner(c, am, bm, a, b, a.y - a.x, b.y - b.x) ||
        hasLinearArtifactInner(c, am, bm, a, b, a.z - a.y, b.z - b.y) ||
        hasLinearArtifactInner(c, am, bm, a, b, a.x - a.z, b.x - b.z))
}

private func hasDiagonalArtifact(_ c: Classifier, _ am: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ cc: SIMD3<Float>, _ d: SIMD3<Float>) -> Bool {
    let dm = med(d)
    if abs(am - 0.5) >= abs(dm - 0.5) {
        let abc = SIMD3<Float>(a.x - b.x - cc.x, a.y - b.y - cc.y, a.z - b.z - cc.z)
        let l = SIMD3<Float>(-a.x - abc.x, -a.y - abc.y, -a.z - abc.z)
        let q = SIMD3<Float>(d.x + abc.x, d.y + abc.y, d.z + abc.z)
        let tEx = [-0.5 * Double(l.x) / Double(q.x), -0.5 * Double(l.y) / Double(q.y), -0.5 * Double(l.z) / Double(q.z)]
        return hasDiagonalArtifactInner(c, am, dm, a, l, q, a.y - a.x, b.y - b.x + cc.y - cc.x, d.y - d.x, tEx[0], tEx[1]) ||
            hasDiagonalArtifactInner(c, am, dm, a, l, q, a.z - a.y, b.z - b.y + cc.z - cc.y, d.z - d.y, tEx[1], tEx[2]) ||
            hasDiagonalArtifactInner(c, am, dm, a, l, q, a.x - a.z, b.x - b.z + cc.x - cc.z, d.x - d.z, tEx[2], tEx[0])
    }
    return false
}

/// msdfErrorCorrection with the default MSDFGeneratorConfig: EDGE_PRIORITY + CHECK_DISTANCE_AT_EDGE, overlap support.
private func mgErrorCorrection(_ px: inout [Float], width w: Int, height h: Int, _ shape: MGShape, _ tr: MGTransform) {
    let sdf = SDFView(px: px, w: w, h: h)
    var stencil = [UInt8](repeating: 0, count: w * h)
    func s(_ x: Int, _ y: Int) -> Int { y * w + x }

    // protectCorners
    for r in shape.ranges where !r.isEmpty {
        var prev = shape.edges[r.upperBound - 1]
        for i in r {
            let e = shape.edges[i]
            let commonColor = prev.color & e.color
            if commonColor & (commonColor - 1) == 0 {
                let p = tr.project(e.point(0))
                let l = Int(floor(p.x - 0.5)), b = Int(floor(p.y - 0.5))
                let rr = l + 1, t = b + 1
                if l < w && b < h && rr >= 0 && t >= 0 {
                    if l >= 0 && b >= 0 { stencil[s(l, b)] |= STENCIL_PROTECTED }
                    if rr < w && b >= 0 { stencil[s(rr, b)] |= STENCIL_PROTECTED }
                    if l >= 0 && t < h { stencil[s(l, t)] |= STENCIL_PROTECTED }
                    if rr < w && t < h { stencil[s(rr, t)] |= STENCIL_PROTECTED }
                }
            }
            prev = e
        }
    }

    // protectEdges
    var radius = Float(PROTECTION_RADIUS_TOLERANCE * vlen(tr.unprojectVector(V(tr.mapDelta1, 0))))
    for y in 0..<h {
        for x in 0..<max(w - 1, 0) {
            let left = sdf.at(x, y), right = sdf.at(x + 1, y)
            let lm = med(left), rm = med(right)
            if abs(lm - 0.5) + abs(rm - 0.5) < radius {
                let mask = edgeBetweenTexels(left, right)
                protectExtremeChannels(&stencil[s(x, y)], left, lm, mask)
                protectExtremeChannels(&stencil[s(x + 1, y)], right, rm, mask)
            }
        }
    }
    radius = Float(PROTECTION_RADIUS_TOLERANCE * vlen(tr.unprojectVector(V(0, tr.mapDelta1))))
    for y in 0..<max(h - 1, 0) {
        for x in 0..<w {
            let bottom = sdf.at(x, y), top = sdf.at(x, y + 1)
            let bm = med(bottom), tm = med(top)
            if abs(bm - 0.5) + abs(tm - 0.5) < radius {
                let mask = edgeBetweenTexels(bottom, top)
                protectExtremeChannels(&stencil[s(x, y)], bottom, bm, mask)
                protectExtremeChannels(&stencil[s(x, y + 1)], top, tm, mask)
            }
        }
    }
    radius = Float(PROTECTION_RADIUS_TOLERANCE * vlen(tr.unprojectVector(V(tr.mapDelta1, tr.mapDelta1))))
    for y in 0..<max(h - 1, 0) {
        for x in 0..<max(w - 1, 0) {
            let lb = sdf.at(x, y), rb = sdf.at(x + 1, y), lt = sdf.at(x, y + 1), rt = sdf.at(x + 1, y + 1)
            let mlb = med(lb), mrb = med(rb), mlt = med(lt), mrt = med(rt)
            if abs(mlb - 0.5) + abs(mrt - 0.5) < radius {
                let mask = edgeBetweenTexels(lb, rt)
                protectExtremeChannels(&stencil[s(x, y)], lb, mlb, mask)
                protectExtremeChannels(&stencil[s(x + 1, y + 1)], rt, mrt, mask)
            }
            if abs(mrb - 0.5) + abs(mlt - 0.5) < radius {
                let mask = edgeBetweenTexels(rb, lt)
                protectExtremeChannels(&stencil[s(x + 1, y)], rb, mrb, mask)
                protectExtremeChannels(&stencil[s(x, y + 1)], lt, mlt, mask)
            }
        }
    }

    let hSpan = MIN_DEVIATION_RATIO * vlen(tr.unprojectVector(V(tr.mapDelta1, 0)))
    let vSpan = MIN_DEVIATION_RATIO * vlen(tr.unprojectVector(V(0, tr.mapDelta1)))
    let dSpan = MIN_DEVIATION_RATIO * vlen(tr.unprojectVector(V(tr.mapDelta1, tr.mapDelta1)))

    /// The eight-neighbour test of findErrors; `make` builds the classifier for a direction and span.
    func texelHasError(_ x: Int, _ y: Int, _ make: (V, Double) -> Classifier) -> Bool {
        let c = sdf.at(x, y)
        let cm = med(c)
        let l = x > 0 ? sdf.at(x - 1, y) : c
        let b = y > 0 ? sdf.at(x, y - 1) : c
        let r = x < w - 1 ? sdf.at(x + 1, y) : c
        let t = y < h - 1 ? sdf.at(x, y + 1) : c
        return (x > 0 && hasLinearArtifact(make(V(-1, 0), hSpan), cm, c, l)) ||
            (y > 0 && hasLinearArtifact(make(V(0, -1), vSpan), cm, c, b)) ||
            (x < w - 1 && hasLinearArtifact(make(V(1, 0), hSpan), cm, c, r)) ||
            (y < h - 1 && hasLinearArtifact(make(V(0, 1), vSpan), cm, c, t)) ||
            (x > 0 && y > 0 && hasDiagonalArtifact(make(V(-1, -1), dSpan), cm, c, l, b, sdf.at(x - 1, y - 1))) ||
            (x < w - 1 && y > 0 && hasDiagonalArtifact(make(V(1, -1), dSpan), cm, c, r, b, sdf.at(x + 1, y - 1))) ||
            (x > 0 && y < h - 1 && hasDiagonalArtifact(make(V(-1, 1), dSpan), cm, c, l, t, sdf.at(x - 1, y + 1))) ||
            (x < w - 1 && y < h - 1 && hasDiagonalArtifact(make(V(1, 1), dSpan), cm, c, r, t, sdf.at(x + 1, y + 1)))
    }

    // findErrors without the distance check, then protectAll (CHECK_DISTANCE_AT_EDGE).
    for y in 0..<h {
        for x in 0..<w {
            let prot = stencil[s(x, y)] & STENCIL_PROTECTED != 0
            if texelHasError(x, y, { dir, span in Classifier(span: span, protectedFlag: prot, checker: nil, direction: dir) }) {
                stencil[s(x, y)] |= STENCIL_ERROR
            }
        }
    }
    for i in stencil.indices { stencil[i] |= STENCIL_PROTECTED }

    // findErrors with the shape distance check (OverlappingContourCombiner<PerpendicularDistanceSelector>).
    let checker = ShapeChecker(sdf, shape, tr)
    var rightToLeft = false
    for y in 0..<h {
        for col in 0..<w {
            let x = rightToLeft ? w - col - 1 : col
            if stencil[s(x, y)] & STENCIL_ERROR != 0 { continue }
            let c = sdf.at(x, y)
            checker.shapeCoord = tr.unproject(V(Double(x) + 0.5, Double(y) + 0.5))
            checker.sdfCoord = V(Double(x) + 0.5, Double(y) + 0.5)
            checker.msd = c
            checker.protectedFlag = stencil[s(x, y)] & STENCIL_PROTECTED != 0
            let prot = checker.protectedFlag
            if texelHasError(x, y, { dir, span in Classifier(span: span, protectedFlag: prot, checker: checker, direction: dir) }) {
                stencil[s(x, y)] |= STENCIL_ERROR
            }
        }
        rightToLeft.toggle()
    }

    // apply
    for i in 0..<(w * h) where stencil[i] & STENCIL_ERROR != 0 {
        let o = i * 3
        let m = mgMedian(px[o], px[o + 1], px[o + 2])
        px[o] = m; px[o + 1] = m; px[o + 2] = m
    }
}

// MARK: - Colour (bitmap) glyphs in MSDF texts

extension MsdfGen {
    /// `Font_AddGlyph` takes this path when the FreeType glyph is not an outline (format ≠ 'outl', 0x1401af028 /
    /// 0x1401af4c5: colour bitmap glyphs such as emoji). `Glyph_BitmapSDF` 0x1401ab9c0 gets the `FT_BitmapGlyph`
    /// (left +0x20, top +0x24, rows +0x28, width +0x2c, pitch +0x30, BGRA buffer +0x38), the output bitmap and the same
    /// scale/translate/range as the outline path (range = 24/scale as a float):
    /// 1. alpha (byte 3) ≥ 0x80 is inside. Grid A = 0 inside, 1e20 outside; grid B = 1e20 inside, 0 outside.
    /// 2. Both grids go through a 2-D Felzenszwalb squared-distance transform (0x1401ac3b0 → 1-D pass 0x1401ac130:
    ///    z[0] = −1e20, z[1] = +1e20, `s ≤ z[k]` pops, `z[k+1] < q` advances; float maths).
    /// 3. Signed distance per pixel, positive inside: inside √B − 0.5, outside −√A + 0.5.
    /// 4. Per output texel (x, y) (y counted bottom-up like msdfgen): sx = f32((x + 0.5)/scale − tx) − left,
    ///    sy = top − f32((y + 0.5)/scale − ty); clamped to [0, W−1] × [0, H−1] (NaN → the upper bound); bilinear sample of
    ///    the distance at the clamped point (x1 = min(ix + 1, W − 1), likewise y), minus the distance from the unclamped
    ///    point to the clamped one; value = that · f32(1/range) + 0.5, written to **all four** channels (0x1401ac058).
    /// The colour is dropped: the glyph becomes a true SDF of its alpha in the MSDF page and draws in the text colour.
    /// `alpha` is row-major, row 0 = the top row (FreeType bitmap order); `left`/`top` in pixels, y up.
    /// Returns width·height floats, row 0 = bottom row.
    static func bitmapField(alpha: [UInt8], bitmapWidth W: Int, bitmapHeight H: Int, left: Int, top: Int,
                            width: Int, height: Int, scale: Double, translate: SIMD2<Double>, range: Float) -> [Float] {
        guard W > 0, H > 0, alpha.count >= W * H, width > 0, height > 0 else { return [] }
        let INF: Float = 1e20
        var outer = [Float](repeating: 0, count: W * H)   // 0 inside: distance to the glyph, for outside pixels
        var inner = [Float](repeating: 0, count: W * H)   // 0 outside: distance to the outside, for inside pixels
        for i in 0..<(W * H) {
            if alpha[i] >= 0x80 { outer[i] = 0; inner[i] = INF } else { outer[i] = INF; inner[i] = 0 }
        }
        edt2D(&outer, W, H, INF)
        edt2D(&inner, W, H, INF)
        var dist = [Float](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            dist[i] = alpha[i] >= 0x80 ? inner[i].squareRoot() - 0.5 : -(outer[i].squareRoot()) + 0.5
        }
        let invRange = Float(1.0 / Double(range))
        let fl = Float(left), ft = Float(top)
        let wm = Float(W - 1), hm = Float(H - 1)
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let shapeY = Float((Double(Float(y)) + 0.5) / scale - translate.y)
            for x in 0..<width {
                var dy = ft - shapeY
                var dx = Float((Double(Float(x)) + 0.5) / scale - translate.x) - fl
                let mx = wm > dx ? dx : wm
                let cx: Float = Double(mx) > 0 ? mx : 0
                let my = hm > dy ? dy : hm
                let cy: Float = Double(my) > 0 ? my : 0
                dx -= cx; dy -= cy
                let fx = cx.rounded(.down), fy = cy.rounded(.down)
                let ix = Int(fx), iy = Int(fy)
                let tx = cx - fx, ty = cy - fy
                let outside = (dy * dy + dx * dx).squareRoot()
                let iy1 = min(iy + 1, H - 1), ix1 = min(ix + 1, W - 1)
                let r0 = iy * W, r1 = iy1 * W
                let top0 = (1 - tx) * dist[r0 + ix] + tx * dist[r0 + ix1]
                let bot = (1 - tx) * dist[r1 + ix] + tx * dist[r1 + ix1]
                out[y * width + x] = (top0 * (1 - ty) + bot * ty - outside) * invRange + 0.5
            }
        }
        return out
    }

    /// 0x1401ac3b0: the 1-D transform over every column, then every row (squared distances, in place).
    private static func edt2D(_ g: inout [Float], _ W: Int, _ H: Int, _ INF: Float) {
        let n = max(W, H)
        var f = [Float](repeating: 0, count: n), d = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n), z = [Float](repeating: 0, count: n + 1)
        for x in 0..<W {
            for y in 0..<H { f[y] = g[y * W + x] }
            edt1D(f, &d, &v, &z, H, INF)
            for y in 0..<H { g[y * W + x] = d[y] }
        }
        for y in 0..<H {
            for x in 0..<W { f[x] = g[y * W + x] }
            edt1D(f, &d, &v, &z, W, INF)
            for x in 0..<W { g[y * W + x] = d[x] }
        }
    }

    /// 0x1401ac130 (Felzenszwalb–Huttenlocher lower envelope of parabolas, float arithmetic).
    private static func edt1D(_ f: [Float], _ d: inout [Float], _ v: inout [Int], _ z: inout [Float], _ n: Int, _ INF: Float) {
        var k = 0
        v[0] = 0; z[0] = -INF; z[1] = INF
        if n > 1 {
            for q in 1..<n {
                let qf = Float(q)
                let fq = qf * qf + f[q]
                var vk = Float(v[k])
                var s = (fq - (vk * vk + f[v[k]])) / Float(2 * (q - v[k]))
                while s <= z[k] {
                    k -= 1
                    vk = Float(v[k])
                    s = (fq - (vk * vk + f[v[k]])) / Float(2 * (q - v[k]))
                }
                k += 1
                v[k] = q; z[k] = s; z[k + 1] = INF
            }
        }
        k = 0
        for q in 0..<n {
            let qf = Float(q)
            while qf > z[k + 1] { k += 1 }
            let r = q - v[k]
            d[q] = Float(r * r) + f[v[k]]
        }
    }
}
