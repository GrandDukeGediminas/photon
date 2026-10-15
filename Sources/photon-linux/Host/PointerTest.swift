#if os(Linux)
import CPhotonWayland
import CX11
import Foundation

/// Stand-in mice for the cursor checks (`photon-linux desktop --pointer-test …`, `--wl-pointer-test …`): XTEST fake
/// input on X11 (it produces the same core and XInput 2 raw events a mouse does) and wlr-virtual-pointer on wlroots
/// compositors (a virtual device on the seat). Actions: `move X Y`, `click X Y`, `press`, `release`, `wait S`.
enum PointerTest {
    static func x11(_ args: [String]) -> Int32 {
        guard let dpy = XOpenDisplay(nil) else { print("pointer test: no X display"); return 1 }
        defer { XCloseDisplay(dpy) }
        var ev: Int32 = 0, er: Int32 = 0, major: Int32 = 0, minor: Int32 = 0
        guard XTestQueryExtension(dpy, &ev, &er, &major, &minor) != 0 else { print("pointer test: no XTEST"); return 1 }
        var a = args[...]
        while let verb = a.first {
            a = a.dropFirst()
            func number() -> Int32 { let v = a.first.flatMap { Int32($0) } ?? 0; a = a.dropFirst(); return v }
            switch verb {
            case "move", "click":
                let x = number(), y = number()
                XTestFakeMotionEvent(dpy, -1, x, y, 0)
                XSync(dpy, 0)
                print("pointer test: \(verb) \(x),\(y)")
                if verb == "click" {
                    Thread.sleep(forTimeInterval: 0.05)
                    XTestFakeButtonEvent(dpy, 1, 1, 0); XSync(dpy, 0)
                    Thread.sleep(forTimeInterval: 0.15)
                    XTestFakeButtonEvent(dpy, 1, 0, 0); XSync(dpy, 0)
                }
            case "press": XTestFakeButtonEvent(dpy, 1, 1, 0); XSync(dpy, 0); print("pointer test: press")
            case "release": XTestFakeButtonEvent(dpy, 1, 0, 0); XSync(dpy, 0); print("pointer test: release")
            case "wait": Thread.sleep(forTimeInterval: a.first.flatMap(Double.init) ?? 0); a = a.dropFirst()
            default: print("pointer test: unknown action \(verb)"); return 2
            }
        }
        return 0
    }

    /// `<layout w> <layout h> actions…` (the virtual pointer's absolute motion is relative to the output layout).
    static func wayland(_ args: [String]) -> Int32 {
        guard args.count >= 2, let w = Int32(args[0]), let h = Int32(args[1]) else { print(DesktopCommand.usage); return 2 }
        var actions: [String] = []
        var a = args.dropFirst(2)
        while let verb = a.first {
            a = a.dropFirst()
            switch verb {
            case "move", "click":
                actions.append("\(verb) \(a.first ?? "0") \(a.dropFirst().first ?? "0")"); a = a.dropFirst(2)
            case "wait": actions.append("wait \(a.first ?? "0")"); a = a.dropFirst()
            default: actions.append(verb)
            }
        }
        print("wayland pointer test: \(actions.joined(separator: "; "))")
        return photon_wl_pointer_test(w, h, actions.joined(separator: ";"))
    }
}
#endif
