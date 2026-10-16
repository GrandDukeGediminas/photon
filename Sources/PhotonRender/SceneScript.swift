import Foundation
import JavaScriptCore
import PhotonCore
import simd

/// SceneScript runtime (docs/re/08): one JavaScriptCore context per scene running `baseclasses.js`, the
/// JS prelude (ScriptPrelude.swift) and one transformed module per `"script"` binding (ScriptModule.swift).
///
/// Swift's part: find bindings in scene.json, compile them, read/write bound values with the per-type
/// conversions of §2.6 (degrees for `angles`), and serve the generic wrappers' property/method calls from
/// the reflection tables (ScriptReflection.swift). JS does hook dispatch, timers and scope rules, so a frame
/// costs one call into JS (`tick`) plus wrapper traffic from the scripts themselves.
///
/// `PHOTON_SCRIPTLOG=1` prints `console.log`/`console.error` output and script errors.
final class SceneScriptEngine {
    /// A host object exposed to JS. Handles are indices into `refs`.
    enum HostRef {
        case scene
        /// The scene as a generic host object (reflection table `general` + getAnimation): thisObject / thisLayer of
        /// `general` bindings (0x1401730d0 registers them with the scene as owner, 0x140172830 sets it as layer).
        case sceneObject
        case object(SceneObject)
        case instance(ParticleSystemObject)
        case effect(Effect, SceneObject)
        case material(Material, Effect, SceneObject)
        /// Binding target only: constantshadervalues of an effect's JSON pass.
        case constants(Effect, Int, SceneObject)
        case propertyAnimation(SceneObject, String)
        /// An animation not stored on an object (effect constants, ScriptConstantAnimations).
        case anim(PropertyAnimation)
        case textureAnimation(ImageLayer)
        /// The video player of an image layer's texture 0 (`getVideoTexture`).
        case videoTexture(ImageLayer, VideoTexture)
        /// A puppet animation layer of an image layer or a model (by `animationlayers` index).
        case animationLayer(SceneObject, Int)
    }

    /// Value crossing the bridge in its native → JS form (degrees already applied).
    enum SVal {
        case num(Double), str(String), bool(Bool), vec([Float]), host(Int, String), null

        var js: Any {
            switch self {
            case .num(let d): return NSNumber(value: d)
            case .str(let s): return s
            case .bool(let b): return NSNumber(value: b) // CFBoolean → JS boolean
            case .vec(let v): return v.map { NSNumber(value: Double($0)) }
            case .host(let h, let c): return [NSNumber(value: h), c] as [Any]
            case .null: return NSNull()
            }
        }
    }

    struct Binding {
        let ref: HostRef
        let handle: Int
        let key: String
        let type: ScriptReflection.ValueType
        var index = -1
        var mask = 0
        /// Handle of the layer the binding belongs to (binding +0x48); nil for none.
        var layer: Int?
    }

    static let logEnabled = ProcessInfo.processInfo.environment["PHOTON_SCRIPTLOG"] != nil
    /// Offline rendering (photon-tool) runs faster than real time; with this set, `Date.now()` follows scene time
    /// so wall-clock-driven scripts (fades timed with Date.now) reach the state they would have live.
    static var simulatedClock = false

    let context: JSContext
    unowned let scene: SceneRenderer
    private var api: JSValue!
    private var tickFn: JSValue!
    private var mkFn: JSValue!
    private var wrapFn: JSValue!
    private var cursorFn: JSValue!
    private(set) var bindings: [Binding] = []
    var refs: [HostRef] = []
    private var handleByKey: [String: Int] = [:]
    /// Values written to reflected properties this runtime does not model (perspective, castshadow, …),
    /// so a set followed by a get round-trips.
    var stored: [Int: [String: SVal]] = [:]
    /// Bloom dirty bit (S+0xe0 bit 31, set by the bloom change callback 0x1401863e0), consumed after the tick.
    var bloomDirty = false
    private var errorCount = 0
    private var cursorLayers: [Int] = []
    /// An owner-less binding with cursor hooks exists (binding +8 == 0, Scene_HitTest 0x14018a372): every hit object fires.
    private var cursorOwnerless = false
    /// Scene_HitTest state: hovered set S+0x280, pressed set S+0x2c0 (cleared while the button is up).
    private var cursorHovered = Set<ObjectIdentifier>()
    private var cursorPressed = Set<ObjectIdentifier>()
    private var lastPointer = SIMD2<Float>(-1, -1)
    private var lastDown = false
    private var lastScreen = SIMD2<Float>(0, 0)
    private let storage: ScriptStorage
    var wantsAudio = false
    private var initDone = false
    /// Media session (binding manager +0x140), created once a script exports a media hook (0x140177cf0).
    var media: ScriptMedia?
    /// Objects Scene_Load has not created yet while the `general` bindings initialise; thisScene does not see them.
    var hiddenObjects = Set<ObjectIdentifier>()
    /// destroyLayer'd objects (scene pending set S+0x210, host 0x14018b730): hidden from name/id/index lookups and the
    /// layer count/enumeration, removed by Scene_FlushPendingObjects 0x14018b390 right after Bindings_Tick (0x1401802ed).
    var pendingDestroy = Set<ObjectIdentifier>()
    /// animationEvent (hook 6) payloads collected since the last tick: [layer handle | null, owner handle, JSON].
    var pendingAnimEvents: [[Any]] = []
    /// Videos given a script clock by getVideoTexture (advanced every tick).
    var videoClocks: [VideoTexture] = []
    /// Video wrappers handed out (their ended callbacks run in the tick).
    var videoCallbacks: [(VideoTexture, [Int])] = []
    /// Counter for layers made by createAnimationLayer / playSingleAnimation (their index base is 100000).
    var nextCreatedLayer = 0
    /// Puppet animation-layer `addEndedCallback` functions (prelude callback ids) per "a<image>_<layer index>".
    var endedCallbacks: [String: [Int]] = [:]
    /// Per createModelData token: the shape buffer records the update path checks (exe shape +0x238 vector).
    var modelShapes: [Int: [ScriptModelShape]] = [:]
    private var profile: (time: Double, ticks: Int) = (0, 0)

    /// Returns nil when the scene has no scripts (no context is created).
    static func make(scene: SceneRenderer, sceneJSON: [String: Any]) -> SceneScriptEngine? {
        guard Self.containsScript(sceneJSON) else { return nil }
        return SceneScriptEngine(scene: scene, sceneJSON: sceneJSON)
    }

    static func containsScript(_ v: Any) -> Bool {
        if let d = v as? [String: Any] {
            if d["script"] is String { return true }
            return d.values.contains { containsScript($0) }
        }
        if let a = v as? [Any] { return a.contains { containsScript($0) } }
        return false
    }

    private init?(scene: SceneRenderer, sceneJSON: [String: Any]) {
        self.scene = scene
        storage = ScriptStorage(key: scene.wallpaperID)
        guard let ctx = JSContext() else { return nil }
        context = ctx
        ctx.name = "SceneScript"
        // Keep the default behaviour (exception stored on the context) so compile() can report it.
        ctx.exceptionHandler = { c, exc in c?.exception = exc }
        guard let base = scene.resources.fs.read("scripts/jsclasses/baseclasses.js").map({ String(decoding: $0, as: UTF8.self) }) else {
            Self.emit(2, "scripts/jsclasses/baseclasses.js not found; SceneScript disabled")
            return nil
        }
        // baseclasses.js: classic script with `this` = global object (§1.3).
        ctx.evaluateScript(base, withSourceURL: URL(string: "scripts/jsclasses/baseclasses.js"))
        if ctx.exception != nil {
            Self.emit(2, "JS base class error: \(ctx.exception!.toString() ?? "")")
            return nil
        }
        installNatives()
        if Self.simulatedClock {
            ctx.evaluateScript("(function(){var base=Date.now(),t=0;Date.now=function(){return base+t;};globalThis.__photonAdvanceClock=function(ms){t+=ms;};})();")
        }
        guard let factory = ctx.evaluateScript(ScriptPrelude.source, withSourceURL: URL(string: "photon:scenescript-prelude")),
              let api = factory.call(withArguments: [ctx.globalObject!, ctx.objectForKeyedSubscript("__photonNative")!]),
              api.isObject else {
            Self.emit(2, "SceneScript prelude failed: \(ctx.exception?.toString() ?? "")")
            return nil
        }
        ctx.globalObject.deleteProperty("__photonNative")
        self.api = api
        tickFn = api.forProperty("tick")
        mkFn = api.forProperty("mk")
        wrapFn = api.forProperty("wrap")
        cursorFn = api.forProperty("cursor")
        let define = api.forProperty("defineClass")!
        for (name, cls) in ScriptReflection.classes {
            let props = cls.props.map { [$0.name, $0.type.rawValue, $0.flags] as [Any] }
            define.call(withArguments: [name, props, cls.methods])
        }
        api.forProperty("setScene").call(withArguments: [handle(.scene, key: "scene")])
        discover(sceneJSON)
        updateSubscriptions()
        if Self.logEnabled {
            Self.emit(0, "\(bindings.count) script bindings, \(bindings.filter { $0.index >= 0 }.count) compiled")
        }
    }

    // MARK: - Logging

    static func emit(_ level: Int, _ msg: String) {
        guard logEnabled else { return }
        let tag = level == 0 ? "[script] " : level == 1 ? "[script console.error] " : "[script error] "
        FileHandle.standardError.write(Data((tag + msg + "\n").utf8))
    }

    // MARK: - Handles

    func handle(_ ref: HostRef, key: String) -> Int {
        if let h = handleByKey[key] { return h }
        refs.append(ref)
        handleByKey[key] = refs.count - 1
        return refs.count - 1
    }

    func handle(_ o: SceneObject) -> Int { handle(.object(o), key: "o\(ObjectIdentifier(o).hashValue)") }
    func handle(_ e: Effect, _ owner: SceneObject) -> Int { handle(.effect(e, owner), key: "e\(ObjectIdentifier(e).hashValue)") }

    func className(_ ref: HostRef) -> String {
        switch ref {
        case .scene: return "scene"
        case .sceneObject: return "sceneobject"
        case .object(let o):
            switch o {
            case is ImageLayer: return "image"
            case is TextObject: return "text"
            case is ParticleSystemObject: return "particle"
            case is SoundObject: return "sound"
            case is CameraObject: return "camera"
            case is ModelObject: return "model"
            default:
                if o.json["light"] != nil { return "light" }
                if let m = o.json["model"], !(m is NSNull) { return "model" }
                return "group"
            }
        case .instance: return "instance"
        case .effect: return "effect"
        case .material: return "material"
        case .constants: return "material"
        case .propertyAnimation, .anim: return "propertyanimation"
        case .textureAnimation: return "textureanimation"
        case .videoTexture: return "videotexture"
        case .animationLayer: return "animationlayer"
        }
    }

    func isValid(_ h: Int) -> Bool {
        guard h >= 0, h < refs.count else { return false }
        if case .object(let o) = refs[h] { return scene.objects.contains { $0 === o } }
        return true
    }

    func jsWrap(_ h: Int) -> JSValue { wrapFn.call(withArguments: [h, className(refs[h])]) }
    func jsWrap(_ o: SceneObject?) -> JSValue {
        guard let o else { return JSValue(nullIn: context) }
        return jsWrap(handle(o))
    }
    func jsMk(_ type: Int, _ v: [Float]) -> JSValue { mkFn.call(withArguments: [type, v.map { Double($0) }]) }

    // MARK: - Natives

    private func installNatives() {
        let N = JSValue(newObjectIn: context)!
        // Plain Swift closures, bridged to JS functions by `scriptNative` (ScriptNativeFunction.swift).
        let log: (Int, String) -> Void = { level, msg in
            Self.emit(level, msg)
        }
        let get: (Int, String) -> Any = { [weak self] h, name in
            guard let self, h >= 0, h < self.refs.count else { return NSNull() }
            return self.get(self.refs[h], h, name).js
        }
        let set: (Int, String, JSValue) -> Void = { [weak self] h, name, v in
            guard let self, h >= 0, h < self.refs.count else { return }
            self.set(self.refs[h], h, name, Self.sval(v))
        }
        let call: (Int, String, JSValue, String) -> JSValue = { [weak self] h, name, args, curKey in
            guard let self, h >= 0, h < self.refs.count else { return JSValue(undefinedIn: JSContext.current()) }
            let list = (0..<Int(args.forProperty("length").toInt32())).map { args.atIndex($0)! }
            return self.call(self.refs[h], h, name, list, curKey) ?? JSValue(undefinedIn: self.context)
        }
        let className: (Int) -> String = { [weak self] h in
            guard let self, h >= 0, h < self.refs.count else { return "object" }
            return self.className(self.refs[h])
        }
        let valid: (Int) -> Bool = { [weak self] h in self?.isValid(h) ?? false }
        let loadModule: (String) -> JSValue = { [weak self] path in
            guard let self else { return JSValue(nullIn: JSContext.current()) }
            return self.compileModule(path: "scripts/jsmodules/" + path)
        }
        // Snapshot at load: the host may load other scenes (other displays) with different properties later.
        // `typedOnly`: the applyUserProperties form, which keeps only entries with both `value` and `type`
        // (0x140173a88–0x140173ad4); engine.userProperties reads the whole set, media-session entries included.
        let propValues = UserProperties.current, propTypes = UserProperties.types
        let userProps: (Bool) -> String = { [weak self] typedOnly in
            var d: [String: Any] = [:]
            if !typedOnly, let m = self?.media?.userProperties { d = m }
            for (k, v) in propValues {
                d[k] = ["type": propTypes[k] ?? "", "value": v]
            }
            return Self.jsonString(d) ?? "{}"
        }
        let shortcut: (String) -> Int = { [weak self] name in
            self?.runUserShortcut(name, values: propValues, types: propTypes) ?? 1
        }
        let mediaSession: () -> Bool = { [weak self] in self?.media != nil }
        let storage: (Int, String, String, String) -> Any = { [weak self] op, loc, key, value in
            guard let self else { return NSNull() }
            switch op {
            case 0: self.storage.set(loc, key, value)
            case 1: return self.storage.get(loc, key) ?? NSNull()
            case 2: self.storage.delete(loc, key)
            default: self.storage.clear(loc)
            }
            return NSNull()
        }
        let audio: () -> Any = { [weak self] in
            guard let self else { return [] as [Any] }
            self.wantsAudio = true
            let a = self.scene.frame.audio
            return [a.left16, a.right16, a.left32, a.right32, a.left64, a.right64].map { $0.map { NSNumber(value: $0) } }
        }
        N.setObject(scriptNative(log), forKeyedSubscript: "log" as NSString)
        N.setObject(scriptNative(get), forKeyedSubscript: "get" as NSString)
        N.setObject(scriptNative(set), forKeyedSubscript: "set" as NSString)
        N.setObject(scriptNative(call), forKeyedSubscript: "call" as NSString)
        N.setObject(scriptNative(className), forKeyedSubscript: "className" as NSString)
        N.setObject(scriptNative(valid), forKeyedSubscript: "valid" as NSString)
        N.setObject(scriptNative(loadModule), forKeyedSubscript: "loadModule" as NSString)
        N.setObject(scriptNative(userProps), forKeyedSubscript: "userProperties" as NSString)
        N.setObject(scriptNative(storage), forKeyedSubscript: "storage" as NSString)
        N.setObject(scriptNative(audio), forKeyedSubscript: "audio" as NSString)
        N.setObject(scriptNative(shortcut), forKeyedSubscript: "shortcut" as NSString)
        N.setObject(scriptNative(mediaSession), forKeyedSubscript: "mediaSession" as NSString)
        context.setObject(N, forKeyedSubscript: "__photonNative" as NSString)
    }

    static func jsonString(_ v: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// JS primitive (already converted by the prelude's `fromJS`) → SVal.
    static func sval(_ v: JSValue) -> SVal {
        if v.isBoolean { return .bool(v.toBool()) }
        if v.isNumber { return .num(v.toDouble()) }
        if v.isString { return .str(v.toString()) }
        if v.isArray, let a = v.toArray() { return .vec(a.map { Float(($0 as? NSNumber)?.doubleValue ?? 0) }) }
        return .null
    }

    // MARK: - Compilation

    private var moduleCache: [String: JSValue] = [:]

    /// Transforms and evaluates a module file into its factory function (JS `require` caches namespaces).
    func compileModule(path: String) -> JSValue {
        guard let data = scene.resources.fs.read(path) else {
            Self.emit(2, "module not found: \(path)")
            return JSValue(nullIn: context)
        }
        return compile(String(decoding: data, as: UTF8.self), name: path) ?? JSValue(nullIn: context)
    }

    func compile(_ source: String, name: String) -> JSValue? {
        let t = ScriptModule.transform(source)
        let fn = context.evaluateScript(t.source, withSourceURL: URL(string: "scene:" + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))
        if let exc = context.exception {
            context.exception = nil
            let line = exc.forProperty("line").toInt32(), col = exc.forProperty("column").toInt32()
            Self.emit(2, "\(name): \(exc.toString() ?? "") (line \(line), col \(col))")
            errorCount += 1
            return nil
        }
        return fn
    }

    // MARK: - Binding discovery (docs/re/08 §2.1)

    /// Reflection order for keys of one object, so registration order is stable (JSON key order is lost).
    private static let keyOrder: [String: Int] = {
        var d: [String: Int] = [:]
        for (i, p) in (ScriptReflection.objectBase + ScriptReflection.group + ScriptReflection.image1 + ScriptReflection.image2
                       + ScriptReflection.text).enumerated() where d[p.name] == nil { d[p.name] = i }
        return d
    }()

    private static func sortedKeys(_ d: [String: Any]) -> [String] {
        d.keys.sorted { (keyOrder[$0] ?? 1000, $0) < (keyOrder[$1] ?? 1000, $1) }
    }

    /// Registration order follows Scene_Load 0x140186c90: the `general` bindings first (0x1401730d0, owner and
    /// layer = the scene), then each object as it is created (Scene_CreateObject 0x14018ff60).
    private func discover(_ sceneJSON: [String: Any]) {
        if let general = sceneJSON["general"] as? [String: Any] {
            let sh = handle(.sceneObject, key: "sceneobject")
            for key in Self.sortedKeys(general) {
                if let b = general[key] as? [String: Any], b["script"] is String {
                    add(.scene, handle(.scene, key: "scene"), key, b, objectHandle: sh, layerHandle: sh, name: "general_\(key)")
                }
            }
        }
        for obj in scene.objects { discoverObject(obj) }
    }

    /// The script bindings of one object (its own properties, instance override, effect `visible` and pass
    /// constants, puppet animation layers). Returns the indices into `bindings` that were added.
    @discardableResult
    func discoverObject(_ obj: SceneObject) -> [Int] {
        let first = bindings.count
        let json = obj.json
        let oh = handle(obj)
        let oname = (json["name"] as? String) ?? "\(obj.id)"
        for key in Self.sortedKeys(json) {
            let v = json[key]
            if key == "instanceoverride", let io = v as? [String: Any], let p = obj as? ParticleSystemObject {
                let ih = handle(.instance(p), key: "i\(ObjectIdentifier(p).hashValue)")
                for k in Self.sortedKeys(io) {
                    if let b = io[k] as? [String: Any], b["script"] is String {
                        add(.instance(p), ih, k, b, objectHandle: ih, layerHandle: oh, name: "\(oname)_instanceoverride_\(k)")
                    }
                }
                continue
            }
            if key == "effects", let list = v as? [Any] {
                for (ei, e) in list.enumerated() {
                    guard let e = e as? [String: Any], let effect = effects(of: obj).first(where: { $0.jsonIndex == ei }) else { continue }
                    let eh = handle(effect, obj)
                    if let b = e["visible"] as? [String: Any], b["script"] is String {
                        add(.effect(effect, obj), eh, "visible", b, objectHandle: eh, layerHandle: oh, name: "\(oname)_effect\(ei)_visible")
                    }
                    for (pi, p) in ((e["passes"] as? [Any]) ?? []).enumerated() {
                        guard let csv = (p as? [String: Any])?["constantshadervalues"] as? [String: Any] else { continue }
                        for k in Self.sortedKeys(csv) {
                            guard let b = csv[k] as? [String: Any], b["script"] is String else { continue }
                            let ch = handle(.constants(effect, pi, obj), key: "c\(ObjectIdentifier(effect).hashValue)_\(pi)")
                            add(.constants(effect, pi, obj), ch, k, b, objectHandle: eh, layerHandle: oh, name: "\(oname)_\(k)")
                        }
                    }
                }
                continue
            }
            if key == "animationlayers", let list = v as? [Any], obj is ImageLayer || obj is ModelObject {
                let img = obj
                for (li, l) in list.enumerated() {
                    guard let l = l as? [String: Any] else { continue }
                    let ah = handle(.animationLayer(img, li), key: "a\(ObjectIdentifier(img).hashValue)_\(li)")
                    for k in Self.sortedKeys(l) {
                        if let b = l[k] as? [String: Any], b["script"] is String {
                            add(.animationLayer(img, li), ah, k, b, objectHandle: ah, layerHandle: oh, name: "\(oname)_animationlayer\(li)_\(k)")
                        }
                    }
                }
                continue
            }
            if let b = v as? [String: Any], b["script"] is String {
                add(.object(obj), oh, key, b, objectHandle: oh, layerHandle: oh, name: "\(oname)_\(key)")
            }
        }
        return Array(first..<bindings.count)
    }

    func effects(of o: SceneObject) -> [Effect] {
        if let i = o as? ImageLayer { return i.effects }
        if let t = o as? TextObject { return t.effects }
        return []
    }

    /// Reflection type of a bound property; untabled keys are typed from their JSON `value`.
    func valueType(_ ref: HostRef, _ key: String, json: [String: Any]?) -> ScriptReflection.ValueType {
        if case .constants(let effect, let pass, _) = ref {
            for p in effect.passes where p.jsonIndex == pass {
                if let info = p.material?.program?.info, let v = info.values.values.first(where: { $0.materialKey == key }) {
                    switch v.components { case 2: return .vec2; case 3: return .vec3; case 4: return .vec4; default: return .float }
                }
            }
        } else if let p = ScriptReflection.classes[className(ref)]?.index[key] {
            return p.type
        }
        switch json?["value"] {
        case let n as NSNumber:
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool : .float
        case let s as String:
            let n = s.split(separator: " ").count
            if n >= 2 && n <= 4 && s.split(separator: " ").allSatisfy({ Float($0) != nil }) {
                return n == 2 ? .vec2 : n == 3 ? .vec3 : .vec4
            }
            return .string
        default:
            return .string
        }
    }

    private func add(_ ref: HostRef, _ h: Int, _ key: String, _ b: [String: Any], objectHandle: Int, layerHandle: Int?, name: String) {
        guard let src = b["script"] as? String else { return }
        var binding = Binding(ref: ref, handle: h, key: key, type: valueType(ref, key, json: b))
        var propsJSON: Any = NSNull()
        if let sp = b["scriptproperties"] as? [String: Any] {
            // Plain entries or {"value", "user"} bound to user properties (§4, 0x140174dc0).
            var resolved: [String: Any] = [:]
            for (k, v) in sp { resolved[k] = unwrapUserValue(v) ?? NSNull() }
            if let s = Self.jsonString(resolved) { propsJSON = s }
        }
        if let fn = compile(src, name: name) {
            let idx = api.forProperty("create").call(withArguments: [fn, objectHandle, layerHandle.map { $0 as Any } ?? NSNull(),
                                                                     binding.type.rawValue, key, name, propsJSON])
            binding.index = Int(idx?.toInt32() ?? -1)
            if binding.index >= 0 { binding.mask = Int(api.forProperty("mask").call(withArguments: [binding.index]).toInt32()) }
        }
        // JS script indices are dense over successfully created scripts; keep only those here.
        binding.layer = layerHandle
        if binding.index >= 0 { bindings.append(binding) }
    }

    /// Cursor-interactive layers (mask bits 7–13) and the media session (bits 14–18), as `Binding_Register`
    /// 0x1401766e2–0x14017670a sets them up.
    func updateSubscriptions() {
        cursorLayers = (api.forProperty("cursorLayers").call(withArguments: []).toArray() as? [NSNumber])?.map(\.intValue) ?? []
        cursorOwnerless = api.forProperty("cursorOwnerless").call(withArguments: []).toBool()
        if media == nil, bindings.contains(where: { $0.mask & 0x7c000 != 0 }) { media = ScriptMedia() }
    }

    /// Runs init for the given bindings (`0x140172830`) and writes the results back.
    private func initBindings(_ list: [Int]) {
        guard !list.isEmpty else { return }
        let values = list.map { get(bindings[$0].ref, bindings[$0].handle, bindings[$0].key).js }
        let out = api.forProperty("initScripts").call(withArguments: [list.map { bindings[$0].index }, values])
        checkException("init")
        if let results = out?.toArray() {
            for (j, r) in results.enumerated() where j < list.count && !(r is NSNull) {
                let b = bindings[list[j]]
                set(b.ref, b.handle, b.key, Self.fromResult(r, b.type))
            }
        }
    }

    /// Scene_Load 0x140186c90 order: the `general` bindings initialise right after they are registered, before any
    /// object exists (0x14018747c / 0x1401874ab); the objects are then created with init deferred (binding manager
    /// +0x134 raised at 0x140187ead, so Scene_CreateObject's 0x14019094d only marks them), and once the loop is done
    /// (+0x134 lowered, 0x140187f72) every object binding initialises in registration order (0x140187f82). Then the
    /// load-time applyUserProperties pass.
    private func initialLoad() {
        hiddenObjects = Set(scene.objects.map { ObjectIdentifier($0) })
        let general = bindings.indices.filter { bindings[$0].layer == handle(.sceneObject, key: "sceneobject") }
        initBindings(general)
        hiddenObjects.removeAll()
        initBindings(bindings.indices.filter { !general.contains($0) })
        api.forProperty("loadUserProperties").call(withArguments: [])
        checkException("applyUserProperties")
    }

    /// A layer created by thisScene.createLayer (Scene_CreateObject 0x14018baea → 0x14018ff60): its bindings are
    /// registered and initialised immediately, inside the createLayer call.
    func registerCreated(_ o: SceneObject) {
        scene.constantAnimations?.add(o)
        let added = discoverObject(o)
        guard !added.isEmpty else { return }
        updateSubscriptions()
        initBindings(added)
    }

    // MARK: - Frame

    /// Runs one `Bindings_Tick` (docs/re/08 §2.3) and writes return values back. Called after the objects'
    /// own update (animations) so script results win for the frame being drawn.
    func tick(dt: Float) {
        let t0 = Self.logEnabled ? CFAbsoluteTimeGetCurrent() : 0
        defer {
            if Self.logEnabled {
                profile.time += CFAbsoluteTimeGetCurrent() - t0
                profile.ticks += 1
                if profile.ticks == 300 {
                    Self.emit(0, String(format: "tick: %.3f ms avg over 300 frames (%d bindings)", profile.time / 300 * 1000, bindings.count))
                    profile = (0, 0)
                }
            }
        }
        if Self.simulatedClock { context.objectForKeyedSubscript("__photonAdvanceClock")?.call(withArguments: [Double(dt) * 1000]) }
        let f = scene.frame
        let world = cursorWorld()
        let sp = SIMD2(f.pointer.x * f.screen.x, f.pointer.y * f.screen.y)
        if f.screen != lastScreen {
            if lastScreen != .zero { api.forProperty("resize").call(withArguments: [Double(f.screen.x), Double(f.screen.y)]) }
            lastScreen = f.screen
        }
        let frameArr: [Double] = [Double(dt), Double(f.time), Double(f.daytime), Double(f.screen.x), Double(f.screen.y),
                                  Double(scene.orthoSize.x), Double(scene.orthoSize.y), Double(world.x), Double(world.y), Double(world.z),
                                  Double(sp.x), Double(sp.y), scene.pointerDown ? 1 : 0]
        if !initDone {
            initDone = true
            api.forProperty("setFrame").call(withArguments: [frameArr])
            initialLoad()
        }
        collectAnimationEvents()
        runEndedCallbacks()
        for v in videoClocks { v.scriptClock?.advance(Double(f.time), duration: v.duration) }
        for (v, ids) in videoCallbacks where v.scriptClock?.takeEnded() == true {
            for id in ids { api.forProperty("callback").call(withArguments: [id]) }
        }
        // Current values only for scripts that receive one this frame (update every frame, animationEvent).
        let animEvents = pendingAnimEvents
        pendingAnimEvents.removeAll()
        var values: [Any] = []
        values.reserveCapacity(bindings.count)
        for b in bindings {
            let wants = b.mask & 2 != 0 || (!animEvents.isEmpty && b.mask & 0x40 != 0)
            values.append(wants ? get(b.ref, b.handle, b.key).js : NSNull())
        }
        let polled = media?.poll(time: f.time) ?? []
        if let m = media, polled.contains(where: { $0.flags & 2 != 0 }) { mediaThumbnailChanged(m) }
        let mediaEvents = polled.map(\.js)
        let out = tickFn.call(withArguments: [frameArr, values, mediaEvents.isEmpty ? NSNull() : mediaEvents,
                                              animEvents.isEmpty ? NSNull() : animEvents])
        checkException("tick")
        if let out, let results = out.toArray() {
            for (i, r) in results.enumerated() where i < bindings.count && !(r is NSNull) {
                let b = bindings[i]
                set(b.ref, b.handle, b.key, Self.fromResult(r, b.type))
            }
        }
        dispatchCursor(world: world)
        flushPendingDestroys()
        // 0x1401802f5: after Bindings_Tick, a set dirty bit re-uploads the bloom constants (0x140184020).
        if bloomDirty { bloomDirty = false; applyBloomConstants() }
    }

    /// Scene_FlushPendingObjects 0x14018b390 (frame step F11, after Bindings_Tick): every object in the pending set goes
    /// through Scene_RemoveObject 0x1401909c0 (out of the object list S+0x158 and the scene's other lists/maps, then its
    /// deleting destructor).
    func flushPendingDestroys() {
        guard !pendingDestroy.isEmpty else { return }
        let gone = pendingDestroy
        pendingDestroy.removeAll()
        scene.objects.removeAll { gone.contains(ObjectIdentifier($0)) }
    }

    /// Thumbnail events (Bindings_Tick 0x14017174f–0x140171a8d): the session's images and texture names changed, the
    /// `$mediaThumbnail` / `$mediaPreviousThumbnail` user properties take the new names, and every material slot bound
    /// to them is rebound through its listener (0x1401538d0) to the `system` texture of that name.
    private func mediaThumbnailChanged(_ m: ScriptMedia) {
        let res = scene.resources
        if res.systemImage == nil { res.systemImage = { [weak m] name in m?.systemImage(name) } }
        var changed: [(String, String)] = [("$mediaThumbnail", m.thumbnailName)]
        if !m.previousThumbnailName.isEmpty { changed.append(("$mediaPreviousThumbnail", m.previousThumbnailName)) }
        for (k, v) in changed {
            res.userTextures[k] = v
            for w in res.userTextureMaterials { w.material?.userPropertyChanged(k, value: v, scene: res) }
        }
    }

    static func fromResult(_ r: Any, _ type: ScriptReflection.ValueType) -> SVal {
        switch type {
        case .bool, .byte: return .bool((r as? NSNumber)?.boolValue ?? false)
        case .string: return .str((r as? String) ?? "\(r)")
        case .vec2, .vec3, .vec4: return .vec(((r as? [Any]) ?? []).map { Float(($0 as? NSNumber)?.doubleValue ?? 0) })
        default: return .num((r as? NSNumber)?.doubleValue ?? 0)
        }
    }

    /// animationEvent sources: property animations (Bindings_Tick 0x1401726c0: binding owner/layer) and puppet /
    /// model animation layers (0x14020021a / 0x14021cdae: the layer as both). The dispatcher 0x140177ad0 sends an
    /// event to every initialised script whose layer or owner is that object.
    private func collectAnimationEvents() {
        let listening = bindings.contains { $0.mask & 0x40 != 0 }
        for o in scene.objects {
            var fired: [String] = []
            for key in o.animations.keys.sorted() { fired += o.animations[key]!.takeEvents() }
            if let p = (o as? ImageLayer)?.puppet { fired += p.firedEvents; p.firedEvents.removeAll() }
            if let p = (o as? ModelObject)?.skeleton { fired += p.firedEvents; p.firedEvents.removeAll() }
            guard listening, !fired.isEmpty else { continue }
            let h = handle(o)
            for j in fired { pendingAnimEvents.append([h, h, j]) }
        }
    }

    private func runEndedCallbacks() {
        for img in scene.objects {
            guard let p = Self.puppet(img), !p.endedLayers.isEmpty else { continue }
            let ended = p.endedLayers
            p.endedLayers.removeAll()
            for idx in ended {
                for id in endedCallbacks["a\(ObjectIdentifier(img).hashValue)_\(idx)"] ?? [] {
                    api.forProperty("callback").call(withArguments: [id])
                }
            }
            // playSingleAnimation layers are deleted after their ended callbacks (0x14020035d–0x1402003b6).
            p.layers.removeAll { $0.singleShot && ended.contains($0.jsonIndex) }
        }
    }

    /// Near and far points of the cursor ray.
    func cursorRay() -> (SIMD3<Float>, SIMD3<Float>) {
        let f = scene.frame
        let ndc = SIMD2(f.pointer.x * 2 - 1, 1 - f.pointer.y * 2)
        let inv = (f.proj * f.view).inverse
        func un(_ z: Float) -> SIMD3<Float> {
            let p = inv * SIMD4(ndc.x, ndc.y, z, 1)
            return SIMD3(p.x, p.y, p.z) / (p.w == 0 ? 1 : p.w)
        }
        return (un(0), un(1))
    }

    /// Pointer (0…1, y down) unprojected onto the z = 0 plane of the scene.
    func cursorWorld() -> SIMD3<Float> {
        let f = scene.frame
        let ndc = SIMD2(f.pointer.x * 2 - 1, 1 - f.pointer.y * 2)
        let inv = (f.proj * f.view).inverse
        func un(_ z: Float) -> SIMD3<Float> {
            let p = inv * SIMD4(ndc.x, ndc.y, z, 1)
            return SIMD3(p.x, p.y, p.z) / (p.w == 0 ? 1 : p.w)
        }
        let a = un(0), b = un(1)
        let d = b - a
        if abs(d.z) > 1e-6 {
            let t = -a.z / d.z
            if t.isFinite { return a + d * t }
        }
        return SIMD3(a.x, a.y, 0)
    }

    /// `Scene_HitTest` 0x140189e10 (docs/re/08 §7.9): one pass over the scene objects per frame, top-down, firing the cursor
    /// hooks (8 enter, 9 leave, 10 move, 11 click, 12 down, 13 up) of the scripts bound to each object.
    /// - Order: the object list S+0x158 from last to first in ortho scenes (S+0xe0 & 8); in perspective scenes a copy sorted
    ///   by `Scene_SortTransparent` 0x1401865c0 (key dot(origin, view forward), `+0x120 & 0x200` → −∞, stable, descending),
    ///   also walked from last to first, i.e. nearest first (0x140189f92–0x140189fe0).
    /// - Only `solid` objects (+0x120 & 0x2000, 0x14018a02d) of type image (1) and text (4) — ray vs quad 0x14019dbb0 — or
    ///   model (5) — ray vs the mdl box 0x140185520 — are tested. Visibility is not checked.
    /// - While a button press is held on some object (pressed set S+0x2c0 non-empty and the button down), only move
    ///   events go to the pressed objects and nothing else happens (0x14018a30e–0x14018a3ca).
    /// - A hit: enter (once, hovered set S+0x280), move (pointer moved), down / up on a button change, click on release over
    ///   an object pressed earlier. A miss: up on release for a pressed object, leave if it was hovered.
    /// - After a hit on an object with `disablepropagation` (+0x120 & 0x4000) whose parent chain is visible (0x140185010),
    ///   the pass stops: lower objects get no events at all, not even leave (0x14018a86f–0x14018a899).
    /// - The pressed set is cleared whenever the button is up at the end (0x14018a44f–0x14018a46f).
    private func dispatchCursor(world: SIMD3<Float>) {
        guard !cursorLayers.isEmpty || cursorOwnerless else { return }
        let f = scene.frame
        let p = f.pointer, down = scene.pointerDown
        let moved = p != lastPointer
        lastPointer = p
        var scripted: [ObjectIdentifier: Int] = [:]
        for h in cursorLayers where h < refs.count { if case .object(let o) = refs[h] { scripted[ObjectIdentifier(o)] = h } }
        var list = scene.objects
        if !scene.isOrtho {
            let v = f.view
            let forward = -SIMD3(v[0][2], v[1][2], v[2][2])
            let keyed = list.enumerated().map { (i, o) -> (depth: Float, index: Int, object: SceneObject) in
                let last = (o as? ImageLayer)?.sortsLast ?? false
                return (last ? -Float.infinity : simd_dot(o.origin, forward), i, o)
            }
            list = keyed.sorted { a, b in a.depth != b.depth ? a.depth > b.depth : a.index < b.index }.map(\.object)
        }
        let (camA, camB) = cursorRay()
        let parallaxHit = scene.cameraParallax && scene.userParallax && scene.isOrtho
        var perspRay: (SIMD3<Float>, SIMD3<Float>)?
        for o in list.reversed() {
            guard o.solid, o is ImageLayer || o is TextObject || o is ModelObject else { continue }
            let id = ObjectIdentifier(o)
            // `+0x120 & 0x80` (perspective) objects use the scene's perspective ray (S vt+0x40), the rest the camera ray.
            var ray = (camA, camB)
            if o.perspective && scene.isOrtho {
                if perspRay == nil {
                    let v = f.view, pr = f.proj
                    scene.pushPerspective(f)
                    perspRay = cursorRay()
                    f.view = v; f.proj = pr
                }
                ray = perspRay!
            }
            // 0x14018a0a9–0x14018a115: with the parallax view path ((S+0xe0 & 0x108) == 0x108, flag set at 0x140189f24)
            // an image or text object's quad centre is shifted by S+0x334·(origin.xy − S+0x340)·parallaxDepth (the
            // object's own +0x128/+0x12c and +0x170/+0x174, z 0), added in 0x14019dbb0 at 0x14019dd79.
            var shift = SIMD3<Float>(0, 0, 0)
            if parallaxHit, o is ImageLayer || o is TextObject {
                shift = SIMD3(scene.parallaxAmount * (o.origin.x - scene.parallaxP.x) * o.parallaxDepth.x,
                              scene.parallaxAmount * (o.origin.y - scene.parallaxP.y) * o.parallaxDepth.y, 0)
            }
            let local = Self.cursorHit(o, ray.0, ray.1, pointer: p, screen: f.screen, centerShift: shift)
            let hit = local != nil
            let lp = local ?? .zero
            let inPressed = cursorPressed.contains(id)
            // vt+0x88 (image 0x1401fd690: the puppet hit boxes) runs only while something is pressed or the button changed.
            var hitBox: String?
            if !cursorPressed.isEmpty || down != lastDown, let img = o as? ImageLayer, let pup = img.puppet {
                hitBox = pup.hitTest(from: ray.0, to: ray.1, layerWorld: img.layerWorld)
            }
            func fire(_ idx: Int) {
                guard let h = scripted[id] ?? (cursorOwnerless ? -1 : nil) else { return }
                var args: [Any] = [idx, h, 0, [world.x, world.y, world.z].map(Double.init), [lp.x, lp.y, lp.z].map(Double.init)]
                if let hitBox { args.append(hitBox) }
                cursorFn.call(withArguments: args)
            }
            if !cursorPressed.isEmpty && down {
                if inPressed && moved { fire(10) }
                continue
            }
            if hit {
                if !cursorHovered.contains(id) { cursorHovered.insert(id); fire(8) }
                if moved { fire(10) }
                if down != lastDown {
                    fire(down ? 12 : 13)
                    if down { cursorPressed.insert(id) } else if inPressed { fire(11) }
                }
                if o.disablePropagation && o.effectiveVisible { break }
            } else {
                if !down && lastDown && inPressed { fire(13) }
                if cursorHovered.contains(id) { cursorHovered.remove(id); fire(9) }
            }
        }
        if !down { cursorPressed.removeAll() }
        lastDown = down
    }

    /// The per-type ray tests of Scene_HitTest; returns the event's `localPosition` on a hit.
    /// - Image / text (0x14019dbb0): a fullscreen image (`flags304 & 2`) always hits, local = pointer × screen size.
    ///   Otherwise the quad c ± X/2 ± Y/2 (c, X·w, Y·h = rows 3, 0, 1 of vt+0x80 scaled by the size +0x2f0) is intersected
    ///   with 0x14019d5a0 (Möller–Trumbore against p0 = c − X/2 − Y/2, e1 = X, e2 = Y; |det| ≤ FLT_EPSILON misses;
    ///   0 ≤ u, v ≤ 1) and must have t ≥ 0; local = (u·w, (1 − v)·h, 0), pixels from the top-left corner.
    /// - Model (0x140185520): the ray in model space (inverse vt+0x80, 0x14005f730) against the mdl box (mdl +0x1b8 /
    ///   +0x1c4, required max.x > min.x) with the slab test, no range clamp; local = origin + tEnter · direction.
    static func cursorHit(_ o: SceneObject, _ a: SIMD3<Float>, _ b: SIMD3<Float>, pointer: SIMD2<Float>, screen: SIMD2<Float>,
                          centerShift: SIMD3<Float> = .zero) -> SIMD3<Float>? {
        let dir = b - a
        if let m = o as? ModelObject {
            guard let mdl = m.mdl else { return nil }
            let box = mdl.bounds
            guard box.max.x > box.min.x else { return nil }
            let inv = m.world.inverse
            let o4 = inv * SIMD4(a, 1), d4 = inv * SIMD4(dir, 0)
            let org = SIMD3(o4.x, o4.y, o4.z), d = SIMD3(d4.x, d4.y, d4.z)
            var tEnter = -Float.infinity, tExit = Float.infinity
            for k in 0..<3 {
                let inv = 1 / d[k]
                var t0 = (box.min[k] - org[k]) * inv, t1 = (box.max[k] - org[k]) * inv
                if t0 > t1 { swap(&t0, &t1) }
                tEnter = max(tEnter, t0); tExit = min(tExit, t1)
            }
            guard tExit >= tEnter else { return nil }
            return org + d * tEnter
        }
        let M: simd_float4x4, size: SIMD2<Float>
        if let i = o as? ImageLayer {
            if i.fullscreen { return SIMD3(pointer.x * screen.x, pointer.y * screen.y, 0) }
            M = i.layerWorld; size = i.size
        } else if let t = o as? TextObject {
            M = t.layerWorld; size = t.size
        } else { return nil }
        let X = SIMD3(M.columns.0.x, M.columns.0.y, M.columns.0.z) * size.x
        let Y = SIMD3(M.columns.1.x, M.columns.1.y, M.columns.1.z) * size.y
        let c = SIMD3(M.columns.3.x, M.columns.3.y, M.columns.3.z) + centerShift
        let p0 = c - X * 0.5 - Y * 0.5
        let pv = simd_cross(dir, Y)
        let det = simd_dot(X, pv)
        guard abs(det) > Float(bitPattern: 0x3400_0000) else { return nil }
        let inv = 1 / det
        let s = a - p0
        let u = simd_dot(s, pv) * inv
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(s, X)
        let v = simd_dot(dir, q) * inv
        guard v >= 0, v <= 1 else { return nil }
        let t = simd_dot(Y, q) * inv
        guard t >= 0 else { return nil }
        return SIMD3(u * size.x, (1 - v) * size.y, 0)
    }

    /// Reports and clears an exception that escaped into Swift (hooks catch their own; this is the runtime).
    func checkException(_ where_: String) {
        guard let exc = context.exception else { return }
        context.exception = nil
        Self.emit(2, "uncaught in \(where_): \(exc.toString() ?? "?")")
    }

    func destroy() {
        api.forProperty("destroyAll").call(withArguments: [])
    }
}

/// `localStorage` backing (docs/re/08 §3.4): per wallpaper, `global` and `screen` locations, kept as JSON
/// strings and saved to ~/Library/Application Support/photon2/scenestorage/<id>.json.
final class ScriptStorage {
    private var data: [String: [String: String]] = [:]
    private let url: URL?

    init(key: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        url = key.isEmpty ? nil : base?.appendingPathComponent("photon2/scenestorage/\(key).json")
        if let url, let d = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: [String: String]] {
            data = obj
        }
    }

    func get(_ loc: String, _ key: String) -> String? { data[loc]?[key] }
    func set(_ loc: String, _ key: String, _ value: String) { data[loc, default: [:]][key] = value; save() }
    func delete(_ loc: String, _ key: String) { data[loc]?[key] = nil; save() }
    func clear(_ loc: String) { data[loc] = nil; save() }

    private func save() {
        guard let url, let d = try? JSONSerialization.data(withJSONObject: data) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url)
    }
}

extension SceneScriptEngine {
    /// The skeleton runtime of an image puppet (layer +0x4b8) or a model (+0x2d8).
    static func puppet(_ o: SceneObject) -> Puppet? { (o as? ImageLayer)?.puppet ?? (o as? ModelObject)?.skeleton }
}
