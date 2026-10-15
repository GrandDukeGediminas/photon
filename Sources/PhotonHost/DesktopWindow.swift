import AppKit
import MetalKit

/// A borderless window pinned to the desktop layer of one display.
///
/// It sits just above the desktop picture and below Finder's icons, ignores the mouse,
/// and appears on every Space, including next to fullscreen apps.
public final class DesktopWindow: NSWindow {
    public let metalView: MTKView
    public let screenID: CGDirectDisplayID

    public init(screen: NSScreen, device: MTLDevice) {
        screenID = screen.displayID
        metalView = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalView.framebufferOnly = false
        metalView.autoResizeDrawable = true

        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        contentView = metalView
        setFrame(screen.frame, display: false)
    }

    /// AppKit would otherwise pull the window inside the menu bar / notch area.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

public extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
