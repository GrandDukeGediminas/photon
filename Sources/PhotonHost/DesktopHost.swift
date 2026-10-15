import AppKit
import Metal
import MetalKit

/// Draws into one desktop window. The scene renderer will implement this.
public protocol DesktopRenderer: AnyObject {
    func draw(in view: MTKView, screen: CGDirectDisplayID, time: TimeInterval)
}

/// Owns one `DesktopWindow` per connected display and rebuilds them when displays change.
public final class DesktopHost: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    public private(set) var windows: [DesktopWindow] = []
    public weak var renderer: DesktopRenderer?
    private let start = CACurrentMediaTime()
    private var loggedFirstDraw = false

    public init(device: MTLDevice) {
        self.device = device
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    public func show() {
        rebuildWindows()
    }

    @objc private func screensChanged() {
        rebuildWindows()
    }

    private var displayLinks: [CADisplayLink] = []
    /// The engine's `fps` setting; 0 = uncapped.
    public var framesPerSecond = 15 {
        didSet {
            guard framesPerSecond != oldValue else { return }
            for link in displayLinks { Self.cap(link, framesPerSecond) }
        }
    }

    /// Hides every desktop window (a "stop" playback rule destroys the engine's wallpaper windows, 0x140073ac0, so the
    /// system wallpaper shows) and shows them again.
    public var hidden = false {
        didSet {
            guard hidden != oldValue else { return }
            for w in windows { if hidden { w.orderOut(nil) } else { w.orderBack(nil) } }
            for l in displayLinks { l.isPaused = hidden }
        }
    }

    private static func cap(_ link: CADisplayLink, _ fps: Int) {
        let f = Float(fps)
        link.preferredFrameRateRange = f > 0 ? CAFrameRateRange(minimum: f, maximum: f, preferred: f) : .default
    }

    private func rebuildWindows() {
        displayLinks.forEach { $0.invalidate() }
        displayLinks = []
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = DesktopWindow(screen: screen, device: device)
            window.metalView.delegate = self
            // MTKView's own display link does not fire for desktop-level windows; drive frames per screen.
            window.metalView.isPaused = true
            window.metalView.enableSetNeedsDisplay = false
            window.orderBack(nil)
            let link = screen.displayLink(target: window.metalView, selector: #selector(MTKView.draw as (MTKView) -> () -> Void))
            // The engine paces frames to the `fps` setting with QueryPerformanceCounter sleeps (0x1401135fa–0x140113697:
            // the remaining ticks of the current one-second window divided by the frames left in it).
            Self.cap(link, framesPerSecond)
            link.add(to: .main, forMode: .common)
            if hidden { window.orderOut(nil); link.isPaused = true }
            displayLinks.append(link)
            NSLog("photon: window on display %u frame %@", window.screenID, NSStringFromRect(screen.frame))
            return window
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let window = view.window as? DesktopWindow else { return }
        if !loggedFirstDraw { loggedFirstDraw = true; NSLog("photon: first draw on display %u, occlusion visible=%d", window.screenID, window.occlusionState.contains(.visible) ? 1 : 0) }
        renderer?.draw(in: view, screen: window.screenID, time: CACurrentMediaTime() - start)
    }
}
