// Linux stand-in for Apple's JavaScriptCore Objective-C API (docs/linux-port.md §4): JSContext and JSValue over the
// JavaScriptCore C API that WebKitGTK ships (javascriptcoregtk-4.1). Same engine, so script semantics match macOS; this
// file only reproduces the Objective-C bridge (value conversion, exception routing, callback context) for the subset
// PhotonRender's SceneScript uses.
//
// Conversion rules follow JSValue.mm on macOS:
//   Swift/Foundation → JS (JSValue(object:), call arguments, setValue): nil → undefined, NSNull → null, Bool and
//     NSNumber booleans (objCType "c") → boolean, other numbers → number, String → string, Date → Date, arrays → Array,
//     dictionaries → Object (keys stringified), JSValue → itself, JSNativeFunction → Function.
//   JS → Foundation (toObject/toArray/toDictionary): undefined → nil (NSNull inside arrays, skipped inside objects),
//     null → NSNull, boolean → NSNumber(bool), number → NSNumber(double), string → String, Date → Date, Array → [Any],
//     other objects → [String: Any] of their enumerable properties.
// Native functions: Swift on Linux has no `@convention(block)` for these signatures, so a native function is a
// `JSNativeFunction` (a Swift closure over the call's arguments), made into a real JS Function object.

import CJavaScriptCore
import Foundation

// MARK: - Strings

@usableFromInline func jsString(_ s: String) -> JSStringRef { JSStringCreateWithUTF8CString(s) }

func swiftString(_ s: JSStringRef) -> String {
    let n = JSStringGetMaximumUTF8CStringSize(s)
    var buf = [CChar](repeating: 0, count: max(n, 1))
    _ = JSStringGetUTF8CString(s, &buf, n)
    return String(cString: buf)
}

// MARK: - Native functions

/// The arguments of a native-function call, converted on demand like the Objective-C block bridge converts them by
/// the block's parameter types (ObjCCallbackFunction.mm).
public struct JSNativeArguments {
    public let context: JSContext
    public let values: [JSValue]
    public let this: JSValue

    public var count: Int { values.count }
    /// Missing arguments read as undefined.
    public func value(_ i: Int) -> JSValue { i < values.count ? values[i] : JSValue(undefinedIn: context) }
    /// NSInteger parameters: ToNumber, then a C cast to the integer type (CallbackArgumentInteger): truncation toward
    /// zero, NaN → 0 and saturation at the type's range as the arm64 conversion does — not ToInt32 (2^32 + 1 stays
    /// 4294967297, verified against JavaScriptCore.framework).
    public func int(_ i: Int) -> Int {
        let d = value(i).toDouble()
        if d.isNaN { return 0 }
        if d >= 9.223372036854775807e18 { return Int.max }
        if d <= -9.223372036854775808e18 { return Int.min }
        return Int(d.rounded(.towardZero))
    }
    /// Floating-point parameters: ToNumber.
    public func double(_ i: Int) -> Double { value(i).toDouble() }
    /// BOOL parameters: ToBoolean.
    public func bool(_ i: Int) -> Bool { value(i).toBool() }
    /// NSString parameters: ToString (undefined → "undefined").
    public func string(_ i: Int) -> String { value(i).toString() ?? "" }
}

/// A Swift closure exposed to JS as a function. The closure's result is converted like a block's `id` result
/// (JSValue(object:) rules); return `JSNativeFunction.undefined` (or nil) for a void function.
public final class JSNativeFunction {
    public let body: (JSNativeArguments) -> Any?
    public init(_ body: @escaping (JSNativeArguments) -> Any?) { self.body = body }
    /// Result of a void function.
    public static let undefined: Any? = nil
}

private final class NativeRegistry {
    nonisolated(unsafe) static var functions: [OpaquePointer: JSNativeFunction] = [:]
    nonisolated(unsafe) static var contexts: [OpaquePointer: WeakContext] = [:]
    nonisolated(unsafe) static var currentStack: [JSContext] = []
    static let lock = NSRecursiveLock()

    struct WeakContext { weak var context: JSContext? }

    static func context(for ref: JSContextRef?) -> JSContext? {
        guard let ref, let global = JSContextGetGlobalContext(ref) else { return nil }
        return lock.withLock { contexts[global]?.context }
    }
}

private let nativeCallback: JSObjectCallAsFunctionCallback = { ctxRef, function, thisObject, argc, argv, exception in
    guard let function, let ctx = NativeRegistry.context(for: ctxRef),
          let fn = NativeRegistry.lock.withLock({ NativeRegistry.functions[function] }) else {
        return JSValueMakeUndefined(ctxRef)
    }
    var values: [JSValue] = []
    for i in 0..<argc { values.append(JSValue(ref: argv![i]!, context: ctx)) }
    let this: JSValue = thisObject.map { JSValue(ref: $0, context: ctx) } ?? JSValue(undefinedIn: ctx)!
    // beginCallbackWithData / endCallbackWithData: the callback sees a clean `exception`; one it sets (directly or
    // through the exception handler) is thrown into JS when it returns, and the caller's exception is restored.
    let saved = ctx.exception
    ctx.exception = nil
    NativeRegistry.lock.withLock { NativeRegistry.currentStack.append(ctx) }
    let result = fn.body(JSNativeArguments(context: ctx, values: values, this: this))
    NativeRegistry.lock.withLock { _ = NativeRegistry.currentStack.popLast() }
    let ref = JSValue.toRef(result, ctx)
    if let exc = ctx.exception {
        exception?.pointee = exc.ref
        ctx.exception = saved
        return JSValueMakeUndefined(ctxRef)
    }
    ctx.exception = saved
    return ref
}

// MARK: - JSVirtualMachine

public final class JSVirtualMachine {
    public init() {}
}

// MARK: - JSContext

open class JSContext {
    public let ref: JSGlobalContextRef
    public let virtualMachine = JSVirtualMachine()
    /// The pending exception (set by the default exception handler).
    open var exception: JSValue!
    /// Called with every exception thrown out of evaluateScript/call/…; the default stores it in `exception`.
    open var exceptionHandler: ((JSContext?, JSValue?) -> Void)!
    private var ownedFunctions: [OpaquePointer] = []

    public init!() {
        guard let r = JSGlobalContextCreate(nil) else { return nil }
        ref = r
        exceptionHandler = { c, e in c?.exception = e }
        NativeRegistry.lock.withLock { NativeRegistry.contexts[r] = .init(context: self) }
    }

    deinit {
        NativeRegistry.lock.withLock {
            NativeRegistry.contexts[ref] = nil
            for f in ownedFunctions {
                NativeRegistry.functions[f] = nil
            }
        }
        for f in ownedFunctions { JSValueUnprotect(ref, f) }
        JSGlobalContextRelease(ref)
    }

    open var name: String! {
        get {
            guard let s = JSGlobalContextCopyName(ref) else { return nil }
            defer { JSStringRelease(s) }
            return swiftString(s)
        }
        set {
            guard let newValue else { return }
            let s = jsString(newValue)
            JSGlobalContextSetName(ref, s)
            JSStringRelease(s)
        }
    }

    /// The context whose native function is running on this thread (nil outside callbacks).
    open class func current() -> JSContext! { NativeRegistry.lock.withLock { NativeRegistry.currentStack.last } }

    open var globalObject: JSValue! { JSValue(ref: JSContextGetGlobalObject(ref)!, context: self) }

    func notify(_ exc: JSValueRef?) -> JSValue {
        if let exc { exceptionHandler?(self, JSValue(ref: exc, context: self)) }
        return JSValue(undefinedIn: self)
    }

    @discardableResult
    open func evaluateScript(_ script: String!) -> JSValue! { evaluateScript(script, withSourceURL: nil) }

    @discardableResult
    open func evaluateScript(_ script: String!, withSourceURL sourceURL: URL!) -> JSValue! {
        let src = jsString(script ?? "")
        defer { JSStringRelease(src) }
        let url = sourceURL.map { jsString($0.absoluteString) }
        defer { if let url { JSStringRelease(url) } }
        var exc: JSValueRef?
        let r = JSEvaluateScript(ref, src, nil, url, 1, &exc)
        if exc != nil || r == nil { return notify(exc) }
        return JSValue(ref: r!, context: self)
    }

    open func objectForKeyedSubscript(_ key: Any!) -> JSValue! { globalObject.forProperty(key) }
    open func setObject(_ object: Any!, forKeyedSubscript key: Any!) { globalObject.setValue(object, forProperty: key) }

    open subscript(key: String) -> Any! {
        get { objectForKeyedSubscript(key) }
        set { setObject(newValue, forKeyedSubscript: key) }
    }

    func makeFunction(_ fn: JSNativeFunction) -> JSObjectRef {
        let f = JSObjectMakeFunctionWithCallback(ref, nil, nativeCallback)!
        JSValueProtect(ref, f)
        ownedFunctions.append(f)
        NativeRegistry.lock.withLock { NativeRegistry.functions[f] = fn }
        return f
    }
}

// MARK: - JSValue

open class JSValue: CustomStringConvertible {
    public let ref: JSValueRef
    public let context: JSContext!

    public init(ref: JSValueRef, context: JSContext) {
        self.ref = ref
        self.context = context
        JSValueProtect(context.ref, ref)
    }

    deinit { JSValueUnprotect(context.ref, ref) }

    var ctx: JSContextRef { context.ref }

    public convenience init!(undefinedIn context: JSContext!) { self.init(ref: JSValueMakeUndefined(context.ref)!, context: context) }
    public convenience init!(nullIn context: JSContext!) { self.init(ref: JSValueMakeNull(context.ref)!, context: context) }
    public convenience init!(bool value: Bool, in context: JSContext!) { self.init(ref: JSValueMakeBoolean(context.ref, value)!, context: context) }
    public convenience init!(double value: Double, in context: JSContext!) { self.init(ref: JSValueMakeNumber(context.ref, value)!, context: context) }
    public convenience init!(int32 value: Int32, in context: JSContext!) { self.init(ref: JSValueMakeNumber(context.ref, Double(value))!, context: context) }
    public convenience init!(uInt32 value: UInt32, in context: JSContext!) { self.init(ref: JSValueMakeNumber(context.ref, Double(value))!, context: context) }
    public convenience init!(object value: Any!, in context: JSContext!) { self.init(ref: JSValue.toRef(value, context), context: context) }
    public convenience init!(newObjectIn context: JSContext!) { self.init(ref: JSObjectMake(context.ref, nil, nil)!, context: context) }
    public convenience init!(newArrayIn context: JSContext!) {
        var exc: JSValueRef?
        self.init(ref: JSObjectMakeArray(context.ref, 0, nil, &exc)!, context: context)
    }
    public convenience init!(newErrorFromMessage message: String!, in context: JSContext!) {
        var exc: JSValueRef?
        var arg: JSValueRef? = JSValue.toRef(message ?? "", context)
        self.init(ref: JSObjectMakeError(context.ref, 1, &arg, &exc)!, context: context)
    }

    // MARK: Type tests

    public var isUndefined: Bool { JSValueIsUndefined(ctx, ref) }
    public var isNull: Bool { JSValueIsNull(ctx, ref) }
    public var isBoolean: Bool { JSValueIsBoolean(ctx, ref) }
    public var isNumber: Bool { JSValueIsNumber(ctx, ref) }
    public var isString: Bool { JSValueIsString(ctx, ref) }
    public var isObject: Bool { JSValueIsObject(ctx, ref) }
    public var isArray: Bool { JSValueIsArray(ctx, ref) }
    public var isDate: Bool { JSValueIsDate(ctx, ref) }
    public var isSymbol: Bool { JSValueIsSymbol(ctx, ref) }

    // MARK: Conversions

    public func toBool() -> Bool { JSValueToBoolean(ctx, ref) }

    public func toDouble() -> Double {
        var exc: JSValueRef?
        let d = JSValueToNumber(ctx, ref, &exc)
        if exc != nil { _ = context.notify(exc); return .nan }
        return d
    }

    /// ECMAScript ToInt32 of ToNumber (JSValue.toInt32 → JSC::toInt32).
    public func toInt32() -> Int32 { Self.toInt32(toDouble()) }
    public func toUInt32() -> UInt32 { UInt32(bitPattern: Self.toInt32(toDouble())) }

    static func toInt32(_ d: Double) -> Int32 {
        guard d.isFinite else { return 0 }
        let t = d < 0 ? -(-d).rounded(.down) : d.rounded(.down)
        let m = t.truncatingRemainder(dividingBy: 4_294_967_296)
        let u = m < 0 ? m + 4_294_967_296 : m
        return Int32(bitPattern: UInt32(u))
    }

    public func toNumber() -> NSNumber! {
        if isBoolean { return NSNumber(value: toBool()) }
        return NSNumber(value: toDouble())
    }

    public func toString() -> String! {
        var exc: JSValueRef?
        guard let s = JSValueToStringCopy(ctx, ref, &exc) else { _ = context.notify(exc); return nil }
        defer { JSStringRelease(s) }
        return swiftString(s)
    }

    public func toDate() -> Date! {
        guard isDate else { return nil }
        let ms = invokeMethod("getTime", withArguments: []).toDouble()
        return Date(timeIntervalSince1970: ms / 1000)
    }

    public func toObject() -> Any! { Self.toObject(ref, context, depth: 0) }

    public func toArray() -> [Any]! {
        guard isObject else { return nil }
        return Self.array(ref, context, depth: 0)
    }

    public func toDictionary() -> [AnyHashable: Any]! {
        guard isObject else { return nil }
        return Self.dictionary(ref, context, depth: 0)
    }

    public var description: String { toString() ?? "" }

    // MARK: Properties

    func object() -> JSObjectRef? {
        var exc: JSValueRef?
        let o = JSValueToObject(ctx, ref, &exc)
        if exc != nil { _ = context.notify(exc) }
        return o
    }

    static func key(_ k: Any?) -> String {
        switch k {
        case let s as String: return s
        case let s as NSString: return String(describing: s)
        case let n as Int: return String(n)
        case let n as NSNumber: return n.stringValue
        case let k?: return String(describing: k)
        case nil: return "undefined"
        }
    }

    public func forProperty(_ property: Any!) -> JSValue! {
        guard let o = object() else { return JSValue(undefinedIn: context) }
        let name = jsString(Self.key(property))
        defer { JSStringRelease(name) }
        var exc: JSValueRef?
        let v = JSObjectGetProperty(ctx, o, name, &exc)
        if exc != nil || v == nil { return context.notify(exc) }
        return JSValue(ref: v!, context: context)
    }

    public func setValue(_ value: Any!, forProperty property: Any!) {
        guard let o = object() else { return }
        let name = jsString(Self.key(property))
        defer { JSStringRelease(name) }
        var exc: JSValueRef?
        JSObjectSetProperty(ctx, o, name, Self.toRef(value, context), 0, &exc)
        if exc != nil { _ = context.notify(exc) }
    }

    @discardableResult
    public func deleteProperty(_ property: Any!) -> Bool {
        guard let o = object() else { return false }
        let name = jsString(Self.key(property))
        defer { JSStringRelease(name) }
        var exc: JSValueRef?
        let r = JSObjectDeleteProperty(ctx, o, name, &exc)
        if exc != nil { _ = context.notify(exc); return false }
        return r
    }

    public func hasProperty(_ property: Any!) -> Bool {
        guard let o = object() else { return false }
        let name = jsString(Self.key(property))
        defer { JSStringRelease(name) }
        return JSObjectHasProperty(ctx, o, name)
    }

    public func atIndex(_ index: Int) -> JSValue! {
        guard let o = object() else { return JSValue(undefinedIn: context) }
        var exc: JSValueRef?
        let v = JSObjectGetPropertyAtIndex(ctx, o, UInt32(truncatingIfNeeded: index), &exc)
        if exc != nil || v == nil { return context.notify(exc) }
        return JSValue(ref: v!, context: context)
    }

    public func setValue(_ value: Any!, at index: Int) {
        guard let o = object() else { return }
        var exc: JSValueRef?
        JSObjectSetPropertyAtIndex(ctx, o, UInt32(truncatingIfNeeded: index), Self.toRef(value, context), &exc)
        if exc != nil { _ = context.notify(exc) }
    }

    public func objectForKeyedSubscript(_ key: Any!) -> JSValue! { forProperty(key) }
    public func objectAtIndexedSubscript(_ index: Int) -> JSValue! { atIndex(index) }
    public func setObject(_ object: Any!, forKeyedSubscript key: Any!) { setValue(object, forProperty: key) }
    public func setObject(_ object: Any!, atIndexedSubscript index: Int) { setValue(object, at: index) }

    public subscript(key: String) -> Any! {
        get { forProperty(key) }
        set { setValue(newValue, forProperty: key) }
    }

    public subscript(index: Int) -> Any! {
        get { atIndex(index) }
        set { setValue(newValue, at: index) }
    }

    public func isEqual(to value: Any!) -> Bool { JSValueIsStrictEqual(ctx, ref, Self.toRef(value, context)) }
    public func isEqualWithTypeCoercion(to value: Any!) -> Bool {
        var exc: JSValueRef?
        return JSValueIsEqual(ctx, ref, Self.toRef(value, context), &exc)
    }

    // MARK: Calls

    private func refs(_ args: [Any]?) -> [JSValueRef?] { (args ?? []).map { Self.toRef($0, context) } }

    @discardableResult
    public func call(withArguments arguments: [Any]!) -> JSValue! {
        // A non-callable value: JSObjectCallAsFunction returns NULL without an exception, and so does
        // -[JSValue callWithArguments:] (nil, no exception handler call; checked on macOS).
        guard let o = object(), JSObjectIsFunction(ctx, o) else { return nil }
        var a = refs(arguments)
        var exc: JSValueRef?
        let r = a.withUnsafeMutableBufferPointer { p in JSObjectCallAsFunction(ctx, o, nil, p.count, p.baseAddress, &exc) }
        if exc != nil { return context.notify(exc) }
        guard let r else { return nil }
        return JSValue(ref: r, context: context)
    }

    @discardableResult
    public func construct(withArguments arguments: [Any]!) -> JSValue! {
        guard let o = object(), JSObjectIsConstructor(ctx, o) else {
            return context.notify(Self.typeError("value is not a constructor", context))
        }
        var a = refs(arguments)
        var exc: JSValueRef?
        let r = a.withUnsafeMutableBufferPointer { p in JSObjectCallAsConstructor(ctx, o, p.count, p.baseAddress, &exc) }
        if exc != nil || r == nil { return context.notify(exc) }
        return JSValue(ref: r!, context: context)
    }

    @discardableResult
    public func invokeMethod(_ method: String!, withArguments arguments: [Any]!) -> JSValue! {
        guard let o = object() else { return JSValue(undefinedIn: context) }
        let name = jsString(method ?? "")
        defer { JSStringRelease(name) }
        var exc: JSValueRef?
        guard let f = JSObjectGetProperty(ctx, o, name, &exc), exc == nil else { return context.notify(exc) }
        var fexc: JSValueRef?
        guard let fo = JSValueToObject(ctx, f, &fexc), JSObjectIsFunction(ctx, fo) else {
            return context.notify(fexc ?? Self.typeError("\(method ?? "") is not a function", context))
        }
        var a = refs(arguments)
        let r = a.withUnsafeMutableBufferPointer { p in JSObjectCallAsFunction(ctx, fo, o, p.count, p.baseAddress, &exc) }
        if exc != nil || r == nil { return context.notify(exc) }
        return JSValue(ref: r!, context: context)
    }

    static func typeError(_ message: String, _ context: JSContext) -> JSValueRef? {
        var arg: JSValueRef? = toRef(message, context)
        var exc: JSValueRef?
        let e = JSObjectMakeError(context.ref, 1, &arg, &exc)
        return e
    }

    // MARK: Foundation → JS

    static func unwrapOptional(_ v: Any) -> Any? {
        let m = Mirror(reflecting: v)
        guard m.displayStyle == .optional else { return v }
        return m.children.first.map { unwrapOptional($0.value) } ?? nil
    }

    public static func toRef(_ value: Any?, _ context: JSContext) -> JSValueRef {
        toRef(value, context, depth: 0)
    }

    static func toRef(_ value: Any?, _ context: JSContext, depth: Int) -> JSValueRef {
        let c = context.ref
        guard let raw = value, let v = unwrapOptional(raw) else { return JSValueMakeUndefined(c)! }
        // NSNumber objects first, by their own type: a Swift `as Bool` cast would also accept the numbers 0 and 1.
        if type(of: v) is NSNumber.Type, let n = v as? NSNumber {
            // CFBoolean → boolean (objectToValueWithoutCopy); swift-corelibs reports NSNumber(value: Bool) as "c".
            if n.objCType.pointee == CChar(UInt8(ascii: "c")) { return JSValueMakeBoolean(c, n.boolValue)! }
            return JSValueMakeNumber(c, n.doubleValue)!
        }
        switch v {
        case let j as JSValue: return j.ref
        case let f as JSNativeFunction: return context.makeFunction(f)
        case is NSNull: return JSValueMakeNull(c)!
        case let b as Bool: return JSValueMakeBoolean(c, b)!
        case let s as String: return makeString(s, c)
        case let s as Substring: return makeString(String(s), c)
        case let s as NSString: return makeString(String(describing: s), c)
        case let n as Int: return JSValueMakeNumber(c, Double(n))!
        case let n as Int32: return JSValueMakeNumber(c, Double(n))!
        case let n as Int64: return JSValueMakeNumber(c, Double(n))!
        case let n as UInt: return JSValueMakeNumber(c, Double(n))!
        case let n as UInt32: return JSValueMakeNumber(c, Double(n))!
        case let n as UInt8: return JSValueMakeNumber(c, Double(n))!
        case let n as Double: return JSValueMakeNumber(c, n)!
        case let n as Float: return JSValueMakeNumber(c, Double(n))!
        case let d as Date:
            var exc: JSValueRef?
            var ms: JSValueRef? = JSValueMakeNumber(c, d.timeIntervalSince1970 * 1000)
            return JSObjectMakeDate(c, 1, &ms, &exc) ?? JSValueMakeUndefined(c)!
        default: break
        }
        guard depth < 64 else { return JSValueMakeUndefined(c)! }
        if let d = v as? [String: Any] { return makeObject(d.map { ($0.key, $0.value) }, context, depth) }
        if let d = v as? [AnyHashable: Any] { return makeObject(d.map { (key(($0.key.base)), $0.value) }, context, depth) }
        if let d = v as? NSDictionary {
            var pairs: [(String, Any)] = []
            for (k, x) in d { pairs.append((key(k), x)) }
            return makeObject(pairs, context, depth)
        }
        if let a = v as? [Any] {
            var exc: JSValueRef?
            var elems = a.map { Optional(toRef($0, context, depth: depth + 1)) }
            return elems.withUnsafeMutableBufferPointer { p in JSObjectMakeArray(c, p.count, p.baseAddress, &exc) } ?? JSValueMakeUndefined(c)!
        }
        if let a = v as? NSArray { return toRef(a.map { $0 }, context, depth: depth) }
        // Arbitrary objects are wrapped on macOS (JSWrapperMap); none cross the bridge in photon2.
        return JSObjectMake(c, nil, nil)!
    }

    static func makeString(_ s: String, _ c: JSContextRef) -> JSValueRef {
        let js = jsString(s)
        defer { JSStringRelease(js) }
        return JSValueMakeString(c, js)!
    }

    static func makeObject(_ pairs: [(String, Any)], _ context: JSContext, _ depth: Int) -> JSValueRef {
        let c = context.ref
        let o = JSObjectMake(c, nil, nil)!
        for (k, x) in pairs {
            let name = jsString(k)
            var exc: JSValueRef?
            JSObjectSetProperty(c, o, name, toRef(x, context, depth: depth + 1), 0, &exc)
            JSStringRelease(name)
        }
        return o
    }

    // MARK: JS → Foundation

    static func toObject(_ v: JSValueRef, _ context: JSContext, depth: Int) -> Any? {
        let c = context.ref
        if JSValueIsUndefined(c, v) { return nil }
        if JSValueIsNull(c, v) { return NSNull() }
        if JSValueIsBoolean(c, v) { return NSNumber(value: JSValueToBoolean(c, v)) }
        if JSValueIsNumber(c, v) { return NSNumber(value: JSValueToNumber(c, v, nil)) }
        if JSValueIsString(c, v) {
            guard let s = JSValueToStringCopy(c, v, nil) else { return "" }
            defer { JSStringRelease(s) }
            return swiftString(s)
        }
        if JSValueIsDate(c, v) { return JSValue(ref: v, context: context).toDate() }
        guard depth < 64 else { return NSNull() }
        if JSValueIsArray(c, v) { return array(v, context, depth: depth) }
        if JSValueIsObject(c, v) { return dictionary(v, context, depth: depth) }
        return nil
    }

    static func array(_ v: JSValueRef, _ context: JSContext, depth: Int) -> [Any] {
        let c = context.ref
        guard let o = JSValueToObject(c, v, nil) else { return [] }
        let lenName = jsString("length")
        defer { JSStringRelease(lenName) }
        let len = JSValueToNumber(c, JSObjectGetProperty(c, o, lenName, nil), nil)
        let n = len.isFinite && len > 0 ? Int(min(len, Double(1 << 24))) : 0
        var out: [Any] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let e = JSObjectGetPropertyAtIndex(c, o, UInt32(i), nil)
            out.append(e.flatMap { toObject($0, context, depth: depth + 1) } ?? NSNull())
        }
        return out
    }

    static func dictionary(_ v: JSValueRef, _ context: JSContext, depth: Int) -> [String: Any] {
        let c = context.ref
        guard let o = JSValueToObject(c, v, nil) else { return [:] }
        let names = JSObjectCopyPropertyNames(c, o)
        defer { JSPropertyNameArrayRelease(names) }
        var out: [String: Any] = [:]
        for i in 0..<JSPropertyNameArrayGetCount(names) {
            let name = JSPropertyNameArrayGetNameAtIndex(names, i)!
            guard let e = JSObjectGetProperty(c, o, name, nil), let x = toObject(e, context, depth: depth + 1) else { continue }
            out[swiftString(name)] = x
        }
        return out
    }
}

// MARK: - JSManagedValue

/// Apple's conditional retain; photon2 only needs it to hold a value, so it is a strong wrapper.
public final class JSManagedValue {
    public let value: JSValue!
    public init!(value: JSValue!) { self.value = value }
}
