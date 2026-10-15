import Foundation

/// Reflection tables for the generic SceneScript wrappers (docs/re/08 §3.10). Each entry is
/// `name:type[flags]` with the type ids of §2.6 (i int, v2/v3/v4, f float, s string, b bool, o object,
/// y byte) and flags `d` = degrees (flag 4), `r` = read-only (flag 2).
enum ScriptReflection {
    enum ValueType: Int {
        case int = 0, vec2 = 1, vec3 = 2, vec4 = 3, float = 4, string = 5, bool = 6, object = 7, byte = 8

        var components: Int {
            switch self {
            case .vec2: return 2
            case .vec3: return 3
            case .vec4: return 4
            default: return 1
            }
        }
    }

    struct Prop {
        let name: String
        let type: ValueType
        let degrees: Bool
        let readOnly: Bool
        var flags: Int { (degrees ? 4 : 0) | (readOnly ? 2 : 0) }
    }

    struct Class {
        let props: [Prop]
        let methods: [String]
        let index: [String: Prop]
        init(_ props: [Prop], _ methods: [String]) {
            self.props = props
            self.methods = methods
            var idx: [String: Prop] = [:]
            for p in props where idx[p.name] == nil { idx[p.name] = p }
            index = idx
        }
    }

    private static func parse(_ s: String) -> [Prop] {
        s.split(separator: " ").map { item in
            let parts = item.split(separator: ":")
            let name = String(parts[0])
            var code = String(parts[1])
            let degrees = code.hasSuffix("d")
            let readOnly = code.hasSuffix("r")
            if degrees || readOnly { code.removeLast() }
            let type: ValueType
            switch code {
            case "i": type = .int
            case "v2": type = .vec2
            case "v3": type = .vec3
            case "v4": type = .vec4
            case "f": type = .float
            case "s": type = .string
            case "b": type = .bool
            case "o": type = .object
            default: type = .byte
            }
            return Prop(name: name, type: type, degrees: degrees, readOnly: readOnly)
        }
    }
    private static func m(_ s: String) -> [String] { s.split(separator: " ").map(String.init) }

    // §3.10 tables (property maps in wallpaper64.exe noted in the spec).
    static let objectBase = parse("origin:v3 scale:v3 angles:v3d parallaxDepth:v2 sortorder:i name:s solid:b disablepropagation:b")
    static let objectMethods = m("getTransformMatrix rotateObjectSpace lookAt lookAtYaw setParent getParent getChildren getAttachmentIndex getAttachmentMatrix getAttachmentOrigin getAttachmentAngles getAnimation")
    static let group = parse("visible:b")
    static let image1 = parse("size:v2 color:v3 alpha:f brightness:f visible:b perspective:b castshadow:b copybackground:b nointerpolation:b clampuvs:b ledsource:b colorBlendMode:i")
    static let image1Methods = m("getEffect getEffectCount transformAttachmentToTexture")
    static let image2 = parse("alignment:s")
    static let image2Methods = m("getTextureAnimation getVideoTexture getAnimationLayer getAnimationLayerCount createAnimationLayer playSingleAnimation destroyAnimationLayer getBoneCount getBoneTransform setBoneTransform getLocalBoneTransform setLocalBoneTransform getLocalBoneAngles setLocalBoneAngles getLocalBoneOrigin setLocalBoneOrigin getBlendShapeIndex getBlendShapeWeight setBlendShapeWeight getBoneIndex getBoneParentIndex applyBonePhysicsImpulse resetBonePhysicsSimulation")
    static let text = parse("backgroundbrightness:f opaquebackground:b limitwidth:b limitrows:b limituseellipsis:b blockalign:b backgroundcolor:v3 pointsize:f padding:v2 spacing:v2 maxwidth:f maxrows:i msdf:b outline:b blur:b dropshadow:b outlinethickness:f outlinecolor:v3 blursize:f dropshadowsize:f dropshadowopacity:f dropshadowcolor:v3 dropshadowoffset:v2 depthtest:s horizontalalign:s verticalalign:s anchor:s text:s font:s")
    static let particle = parse("visible:b instance:or")
    static let particleMethods = m("play pause stop isPlaying emitParticles")
    static let instance = parse("alpha:f size:f count:f speed:f lifetime:f brightness:f rate:f colorn:v3 controlpoint0:v3 controlpointangle0:v3 controlpoint1:v3 controlpointangle1:v3 controlpoint2:v3 controlpointangle2:v3 controlpoint3:v3 controlpointangle3:v3 controlpoint4:v3 controlpointangle4:v3 controlpoint5:v3 controlpointangle5:v3 controlpoint6:v3 controlpointangle6:v3 controlpoint7:v3 controlpointangle7:v3")
    static let model = parse("visible:b perspective:b castshadow:b rootmotion:b")
    static let modelMethods = m("getAnimationLayer getAnimationLayerCount createAnimationLayer playSingleAnimation destroyAnimationLayer")
    static let sound = parse("volume:f mintime:f maxtime:f attenuation:f mindistance:f playbackmode:s muteineditor:b startsilent:b spatialization:b")
    static let soundMethods = m("play stop pause isPlaying")
    static let light = parse("color:v3 intensity:f radius:f exponent:f innercone:f outercone:f density:f volumetricsexponent:f cascadedistance0:f cascadedistance1:f cascadedistance2:f lightsourcesize:f controlpoint:v3 light:s visible:b castshadow:b usecookie:b castvolumetrics:b")
    /// Camera object (0x1401f3460, property map 0x1404e8460).
    static let camera = parse("visible:b fov:f zoom:f queuemode:s")
    static let general = parse("bloom:b hdr:b bloomstrength:f bloomthreshold:f bloomhdrstrength:f bloomhdrthreshold:f bloomhdrfeather:f bloomhdrscatter:f bloomhdriterations:i bloomtint:v3 clearenabled:b clearcolor:v3 ambientcolor:v3 skylightcolor:v3 fogdistance:b fogheight:b fogdistancecolor:v3 fogheightcolor:v3 fogdistancestart:f fogdistanceend:f fogdistancestartdensity:f fogdistanceenddensity:f fogheightstart:f fogheightend:f fogheightstartdensity:f fogheightenddensity:f fov:f perspectiveoverridefov:f nearz:f farz:f zoom:f camerafade:b transparentsorting:b customsortorder:b camerashake:b camerashakespeed:f camerashakeamplitude:f camerashakeroughness:f cameraparallax:b cameraparallaxamount:f cameraparallaxdelay:f cameraparallaxmouseinfluence:f gravitydirection:v3 gravitystrength:f windenabled:b winddirection:v3 windstrength:f")
    static let sceneMethods = m("getLayer getLayerByID getLayerCount enumerateLayers destroyLayer createLayer sortLayer getLayerIndex getInitialLayerConfig getCameraTransforms setCameraTransforms getAnimation createModelData destroyModelData")
    static let effect = parse("visible:b name:s")
    static let effectMethods = m("getMaterial getMaterialCount setMaterialProperty executeMaterialFunction getAnimation")
    static let material = parse("blending:s alphawriting:s depthtest:s depthwrite:s cullmode:s")
    static let propertyAnimation = parse("rate:f fps:fr frameCount:ir duration:fr name:sr")
    static let animMethods = m("play pause stop isPlaying setFrame getFrame")
    static let textureAnimation = parse("rate:f frameCount:ir duration:fr")
    static let textureAnimationMethods = m("play pause stop isPlaying setFrame getFrame join")
    static let videoTexture = parse("rate:f loop:y duration:fr")
    static let videoTextureMethods = m("play pause stop isPlaying setCurrentTime getCurrentTime addEndedCallback")
    static let animationLayer = parse("visible:b additive:b blendin:b blendout:b name:s rate:f blend:f blendtime:f fps:fr frameCount:ir duration:fr")
    static let animationLayerMethods = m("play pause stop isPlaying setFrame getFrame addEndedCallback")

    /// Concrete wrapper classes: union of the tables base → derived (§3.10).
    static let classes: [String: Class] = [
        "object": Class(objectBase + group, objectMethods),
        "group": Class(objectBase + group, objectMethods),
        "image": Class(objectBase + image1 + image2, objectMethods + image1Methods + image2Methods),
        "text": Class(objectBase + image1 + text, objectMethods + image1Methods),
        "particle": Class(objectBase + particle, objectMethods + particleMethods),
        "model": Class(objectBase + model, objectMethods + modelMethods),
        "sound": Class(objectBase + sound, objectMethods + soundMethods),
        "light": Class(objectBase + light, objectMethods),
        "camera": Class(objectBase + camera, objectMethods),
        "scene": Class(general, sceneMethods),
        // The scene as a generic host object (thisObject/thisLayer of `general` bindings): reflection table only.
        "sceneobject": Class(general, ["getAnimation"]),
        "instance": Class(instance, ["getAnimation"]),
        "effect": Class(effect, effectMethods),
        "material": Class(material, ["getAnimation"]),
        "propertyanimation": Class(propertyAnimation, animMethods),
        "textureanimation": Class(textureAnimation, textureAnimationMethods),
        "videotexture": Class(videoTexture, videoTextureMethods),
        "animationlayer": Class(animationLayer, animationLayerMethods),
    ]
}
