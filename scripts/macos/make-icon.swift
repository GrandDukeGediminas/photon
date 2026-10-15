// Draws photon's app icon (an SF Symbol on a gradient squircle) at every iconset size: make-icon.swift <iconset dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (base, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(px)
        let inset = s * 0.1
        let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        NSGradient(colors: [NSColor(calibratedRed: 0.36, green: 0.22, blue: 0.85, alpha: 1),
                            NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.95, alpha: 1)])!.draw(in: path, angle: -60)
        let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.5, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let sz = sym.size
            sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
