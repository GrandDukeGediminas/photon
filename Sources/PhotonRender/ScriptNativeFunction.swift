import Foundation
import JavaScriptCore

// Native functions handed to SceneScript's JS side (`__photonNative`, SceneScript.installNatives). The closures are
// plain Swift functions; `scriptNative` turns each into what JSContext accepts as a JS function:
// - macOS: the identical `@convention(block)` value JavaScriptCore.framework bridges by the block's signature.
// - Linux: there are no Objective-C blocks for these signatures, so the LinuxCompat JavaScriptCore module takes a
//   `JSNativeFunction`; arguments are converted the way the block bridge converts them (Int: ToNumber → ToInt32,
//   String: ToString, Bool: ToBoolean, JSValue as is) and the result like a block's (JSValue(object:) rules).
// One overload per signature installNatives uses.

#if os(Linux)
func scriptNative(_ f: @escaping (Int, String) -> Void) -> Any { JSNativeFunction { a in f(a.int(0), a.string(1)); return nil } }
func scriptNative(_ f: @escaping (Int, String) -> Any) -> Any { JSNativeFunction { a in f(a.int(0), a.string(1)) } }
func scriptNative(_ f: @escaping (Int, String, JSValue) -> Void) -> Any {
    JSNativeFunction { a in f(a.int(0), a.string(1), a.value(2)); return nil }
}
func scriptNative(_ f: @escaping (Int, String, JSValue, String) -> JSValue) -> Any {
    JSNativeFunction { a in f(a.int(0), a.string(1), a.value(2), a.string(3)) }
}
func scriptNative(_ f: @escaping (Int) -> String) -> Any { JSNativeFunction { a in f(a.int(0)) } }
func scriptNative(_ f: @escaping (Int) -> Bool) -> Any { JSNativeFunction { a in f(a.int(0)) } }
func scriptNative(_ f: @escaping (String) -> JSValue) -> Any { JSNativeFunction { a in f(a.string(0)) } }
func scriptNative(_ f: @escaping (Bool) -> String) -> Any { JSNativeFunction { a in f(a.bool(0)) } }
func scriptNative(_ f: @escaping (String) -> Int) -> Any { JSNativeFunction { a in f(a.string(0)) } }
func scriptNative(_ f: @escaping () -> Bool) -> Any { JSNativeFunction { _ in f() } }
func scriptNative(_ f: @escaping (Int, String, String, String) -> Any) -> Any {
    JSNativeFunction { a in f(a.int(0), a.string(1), a.string(2), a.string(3)) }
}
func scriptNative(_ f: @escaping () -> Any) -> Any { JSNativeFunction { _ in f() } }
#else
func scriptNative(_ f: @escaping (Int, String) -> Void) -> Any { f as @convention(block) (Int, String) -> Void }
func scriptNative(_ f: @escaping (Int, String) -> Any) -> Any { f as @convention(block) (Int, String) -> Any }
func scriptNative(_ f: @escaping (Int, String, JSValue) -> Void) -> Any { f as @convention(block) (Int, String, JSValue) -> Void }
func scriptNative(_ f: @escaping (Int, String, JSValue, String) -> JSValue) -> Any {
    f as @convention(block) (Int, String, JSValue, String) -> JSValue
}
func scriptNative(_ f: @escaping (Int) -> String) -> Any { f as @convention(block) (Int) -> String }
func scriptNative(_ f: @escaping (Int) -> Bool) -> Any { f as @convention(block) (Int) -> Bool }
func scriptNative(_ f: @escaping (String) -> JSValue) -> Any { f as @convention(block) (String) -> JSValue }
func scriptNative(_ f: @escaping (Bool) -> String) -> Any { f as @convention(block) (Bool) -> String }
func scriptNative(_ f: @escaping (String) -> Int) -> Any { f as @convention(block) (String) -> Int }
func scriptNative(_ f: @escaping () -> Bool) -> Any { f as @convention(block) () -> Bool }
func scriptNative(_ f: @escaping (Int, String, String, String) -> Any) -> Any { f as @convention(block) (Int, String, String, String) -> Any }
func scriptNative(_ f: @escaping () -> Any) -> Any { f as @convention(block) () -> Any }
#endif
