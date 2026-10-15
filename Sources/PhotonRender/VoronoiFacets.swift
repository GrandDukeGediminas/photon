import Foundation
import simd

/// `CreateVoronoiFacets` (cloneextensions64.dll 0x180007f90, sha256 69871bed…c3c8), the facets of the glass-shatter
/// transition (docs/re/frame-graph.md §T3, evidence/session7-playlist.md). The DLL embeds jc_voronoi
/// (`jcv_diagram_generate` with the default box clipper and `jcv_boxshape_fillgaps`) and returns, per surviving site,
/// the start point of each of the site's graph edges.
///
/// - Sites: copied as given, sorted by y then x (qsort comparator 0x180001600), and a site within FLT_EPSILON in both
///   coordinates of the previous sorted site is dropped (0x180008404–0x1800085f4). Facets come out in that order.
/// - Rect: the caller's integer rect (−1, −1, 1, 1), converted to float (0x180007fe1).
/// - Per site: the Voronoi graph edges sorted by `atan2(mid.y − site.y, mid.x − site.x)` (+2π below 0) of each edge's
///   midpoint (`jcv_finishline` 0x180003230; atan2f 0x18007bf50), every edge oriented counter-clockwise around the
///   site; then the box-border gaps are filled, each gap edge inserted after the edge where the gap starts, splitting at
///   rect corners. The output polygon is each graph edge's first point in that list order (0x180008fc0–0x18000920d):
///   counter-clockwise (y up), starting at the Voronoi edge with the smallest angle.
///
/// photon2 computes each cell by clipping the rect with the bisector half-planes (the same polygon; vertex positions
/// differ from jc_voronoi's sweep-line arithmetic by float rounding only) and orders it as above.
public enum VoronoiFacets {
    public struct Facet {
        public var site: SIMD2<Float>
        /// Counter-clockwise, starting at the first graph edge.
        public var polygon: [SIMD2<Float>]
    }

    public static func generate(sites input: [SIMD2<Float>], min lo: SIMD2<Float> = SIMD2(-1, -1),
                                max hi: SIMD2<Float> = SIMD2(1, 1)) -> [Facet] {
        let sorted = input.sorted { a, b in a.y != b.y ? a.y < b.y : a.x < b.x }
        var sites: [SIMD2<Float>] = []
        for (i, s) in sorted.enumerated() {
            if i > 0, abs(s.y - sorted[i - 1].y) < Float.ulpOfOne, abs(s.x - sorted[i - 1].x) < Float.ulpOfOne { continue }
            sites.append(s)
        }
        var facets: [Facet] = []
        for (i, s) in sites.enumerated() {
            var poly: [SIMD2<Float>] = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
            for (j, o) in sites.enumerated() where j != i {
                let n = o - s, m = (s + o) * 0.5
                poly = clip(poly) { simd_dot($0 - m, n) }
                if poly.count < 3 { break }
            }
            // Drop repeated points (zero-length edges; jc_voronoi has none).
            var p: [SIMD2<Float>] = []
            for v in poly where p.last.map({ simd_distance($0, v) > 1e-7 }) ?? true { p.append(v) }
            while p.count > 1, simd_distance(p[0], p[p.count - 1]) <= 1e-7 { p.removeLast() }
            guard p.count >= 3 else { continue }
            // First list entry: the non-border edge with the smallest midpoint angle.
            var start = 0, best = Float.greatestFiniteMagnitude
            for k in p.indices {
                let a = p[k], b = p[(k + 1) % p.count]
                let border = (a.x == lo.x && b.x == lo.x) || (a.x == hi.x && b.x == hi.x)
                    || (a.y == lo.y && b.y == lo.y) || (a.y == hi.y && b.y == hi.y)
                if border { continue }
                let mid = (a + b) * 0.5
                let dy = mid.y - s.y
                var angle = atan2f(dy, mid.x - s.x)
                if dy < 0 { angle += 2 * Float.pi }
                if angle < best { best = angle; start = k }
            }
            facets.append(Facet(site: s, polygon: Array(p[start...] + p[..<start])))
        }
        return facets
    }

    /// Sutherland–Hodgman against `f(p) <= 0`.
    static func clip(_ poly: [SIMD2<Float>], _ f: (SIMD2<Float>) -> Float) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            let fa = f(a), fb = f(b)
            if fa <= 0 { out.append(a) }
            if (fa <= 0) != (fb <= 0) { out.append(a + (b - a) * (fa / (fa - fb))) }
        }
        return out
    }
}
