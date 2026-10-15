import Foundation
import PhotonRender

/// `photon-tool hrtf-dump <mediaextensions64.dll> <device rate> <out dir>`: the built-in HRTF store as photon2 builds it
/// (`HrtfStore.builtIn` + `resampled(to:)`) and `HrtfStore.filter` for a fixed set of directions, as raw files for the
/// emulator replay of `GetHrtfCoeffs` 0x18018abc0 / `PPhaseResampler` in mediaextensions64.dll
/// (scratchpad left/audio/emu: hrtf_coeffs.py, hrtf_resample.py, hrtf_mix.py).
func hrtfDump(_ args: [String]) {
    guard args.count >= 3, let rate = Int(args[1]), let raw = HrtfStore.builtIn(dll: URL(fileURLWithPath: args[0])) else {
        print("usage: photon-tool hrtf-dump <dll> <rate> <out dir>"); return
    }
    let dir = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func write(_ name: String, _ s: HrtfStore) {
        let meta: [String: Any] = ["rate": s.sampleRate, "irSize": s.irSize, "fields": s.fields.map { [$0.distance, Float($0.evCount)] },
                                   "elevations": s.elevations.map { [$0.azCount, $0.irOffset] }]
        try? JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("\(name).json"))
        try? s.coeffs.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("\(name).coeffs.f32"))
        try? Data(s.delays).write(to: dir.appendingPathComponent("\(name).delays.u8"))
    }
    write("raw", raw)
    let store = raw.resampled(to: rate)
    write("dev", store)
    // Directions: a deterministic LCG spread plus edge cases.
    var cases: [Float] = []
    var x: UInt32 = 12345
    func rnd() -> Float { x = x &* 1664525 &+ 1013904223; return Float(x >> 8) / Float(1 << 24) }
    let halfPi = Float(bitPattern: 0x3fc9_0fdb), pi = Float(bitPattern: 0x4049_0fdb)
    for e in [-halfPi, 0, halfPi] { for a in [-pi, -pi / 2, 0, pi / 2, pi] { cases += [e, a, .infinity, 0] } }
    cases += [0, Float(bitPattern: 0xbf06_0a92), .infinity, 0, 0, Float(bitPattern: 0x3f06_0a92), .infinity, 0]
    for i in 0..<400 {
        let spread: Float = i % 5 == 0 ? rnd() * 2 * pi : 0
        cases += [asin(rnd() * 2 - 1), (rnd() * 2 - 1) * pi, rnd() * 3, spread]
    }
    var out: [Float] = [], dl: [UInt32] = []
    for c in stride(from: 0, to: cases.count, by: 4) {
        let f = store.filter(elevation: cases[c], azimuth: cases[c + 1], distance: cases[c + 2], spread: cases[c + 3])
        out += f.coeffs; dl += [f.delay.0, f.delay.1]
    }
    try? cases.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("cases.f32"))
    try? out.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("filters.f32"))
    try? dl.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("delays.u32"))
    // Mixer trace for the DoHrtfMix 0x180173e70 replay: a sequence of mixes of one voice channel (sizes, filters, target
    // gains, fading flag = Counter != 0) over a fixed input; per mix the samples that leave the accumulator (since the
    // OpenAL cross-check they include HrtfDirectDelay: the output trails the input by 256 samples).
    let mixes: [(n: Int, c: Int, gain: Float, fading: Bool)] = [
        (480, 20, 0.8, false), (480, 21, 0.6, true), (256, 22, 0.6, true), (1024, 23, 0, true), (480, 23, 0, true),
        (480, 24, 0.5, true), (100, 25, 0.000001, true), (1, 26, 0.3, true), (480, 27, 0.3, false), (64, 28, 1, true)]
    let mf = HrtfVoiceFilter(irSize: store.irSize)
    var mixMeta: [[Any]] = [], mixFilters: [Float] = [], mixDelays: [UInt32] = [], mixIn: [Float] = [], mixOut: [Float] = []
    for m in mixes {
        let f = store.filter(elevation: cases[m.c * 4], azimuth: cases[m.c * 4 + 1], distance: cases[m.c * 4 + 2], spread: cases[m.c * 4 + 3])
        mf.target = f
        let input = (0..<m.n).map { _ in rnd() * 2 - 1 }
        var l = [Float](repeating: 0, count: m.n), r = l
        input.withUnsafeBufferPointer { mf.mix($0.baseAddress!, m.n, fading: m.fading, gain: m.gain, left: &l, right: &r) }
        mixMeta.append([m.n, m.gain, m.fading])
        mixFilters += f.coeffs; mixDelays += [f.delay.0, f.delay.1]; mixIn += input
        for i in 0..<m.n { mixOut += [l[i], r[i]] }
    }
    try? JSONSerialization.data(withJSONObject: ["irSize": store.irSize, "mixes": mixMeta]).write(to: dir.appendingPathComponent("mix.json"))
    try? mixFilters.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("mix.filters.f32"))
    try? mixDelays.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("mix.delays.u32"))
    try? mixIn.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("mix.in.f32"))
    try? mixOut.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("mix.out.f32"))
    print("raw: \(raw.sampleRate) Hz irSize \(raw.irSize) irs \(raw.irCount); dev: \(store.sampleRate) Hz irSize \(store.irSize); \(cases.count / 4) cases")
}

/// `photon-tool sound-ref <mediaextensions64.dll> <out dir>`: photon2's macOS voice output for each of `SoundReference`'s
/// scenes (48 kHz device), as raw float32 stereo: `<scene>.speaker.f32` (`VoiceMixer` with SoundSpatial.ambiGains) and
/// `<scene>.hrtf.f32` (the dll's built-in HRTF set resampled to 48 kHz, HrtfVoiceFilter). `photon-linux sound-check <dir>`
/// compares OpenAL Soft 1.21.1 with them (docs/linux-port.md §3.6). Nothing is played.
func soundRef(_ args: [String]) {
    guard args.count >= 2, let raw = HrtfStore.builtIn(dll: URL(fileURLWithPath: args[0])) else {
        print("usage: photon-tool sound-ref <mediaextensions64.dll> <out dir>"); return
    }
    let dir = URL(fileURLWithPath: args[1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = raw.resampled(to: SoundReference.rate)
    for scene in SoundReference.scenes() {
        let speaker = SoundReference.render(scene, store: nil)
        let hrtf = SoundReference.render(scene, store: store)
        try? speaker.withUnsafeBytes { Data($0) }.write(to: dir.appendingPathComponent("\(scene.name).speaker.f32"))
        try? hrtf.withUnsafeBytes { Data($0) }.write(to: dir.appendingPathComponent("\(scene.name).hrtf.f32"))
        print("sound-ref: \(scene.name): \(scene.steps.count) updates of \(scene.mixFrames) frames, track \(scene.frames) frames at \(scene.sourceRate) Hz\(scene.loops ? " looping" : "")")
    }
    print("sound-ref: device \(SoundReference.rate) Hz; HRTF \(raw.sampleRate) → \(store.sampleRate) Hz, \(store.irSize) taps → \(dir.path)")
}
