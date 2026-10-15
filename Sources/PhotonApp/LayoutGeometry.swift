import Foundation

/// The geometry of the multi-display layouts (docs/re/09 §8.2), shared by the macOS compositor (DisplayLayout.swift)
/// and the Linux app (which hands the stretched box to the X11 host as one output).
package enum LayoutGeometry {
    /// Bounding box of every display and each display's part of it as a UV rectangle (origin, size; y down).
    package static func spanRegions<ID: Hashable>(_ rects: [(id: ID, rect: CGRect, scale: CGFloat)]) -> (box: CGRect, uv: [ID: CGRect]) {
        guard var box = rects.first?.rect else { return (.zero, [:]) }
        for r in rects.dropFirst() { box = box.union(r.rect) }
        var uv: [ID: CGRect] = [:]
        for r in rects {
            uv[r.id] = CGRect(x: (r.rect.minX - box.minX) / box.width, y: (r.rect.minY - box.minY) / box.height,
                              width: r.rect.width / box.width, height: r.rect.height / box.height)
        }
        return (box, uv)
    }

    /// Cover fit of a source with aspect `src` (w/h) onto a target with aspect `dst`: the UV rectangle of the source
    /// that fills the target, centred (0x140069565–0x140069627).
    package static func coverUV(source src: CGFloat, target dst: CGFloat) -> CGRect {
        guard src > 0, dst > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if src > dst {
            let w = dst / src
            return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else {
            let h = src / dst
            return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
    }
}
