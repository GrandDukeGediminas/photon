import Accelerate
import Foundation

/// One block of captured audio, the macOS stand-in for a WASAPI `GetBuffer` packet.
public struct AudioPacket {
    /// Interleaved float32 frames.
    public var samples: [Float]
    public var channels: Int
    /// AUDCLNT_BUFFERFLAGS_SILENT. Capture backends set it for packets that are exactly zero.
    public var silent: Bool
    public var frames: Int { channels > 0 ? samples.count / channels : 0 }

    public init(samples: [Float], channels: Int, silent: Bool) {
        self.samples = samples
        self.channels = channels
        self.silent = silent
    }
}

// MARK: - Analysis thread body (docs/re/06 §5.2, `Audio_Thread` 0x1400d02b0)

/// Turns captured packets into the engine's 128-float spectrum (L[0..63], R[64..127]).
/// Not thread-safe: one owner calls `poll` (the analysis thread, or a test).
public final class AudioAnalyzer {
    public let sampleRate: Double
    /// FFT length N = (int)(max(sr/44100, 1)·64·30) (B+0xF4).
    public let N: Int
    /// Bins examined M = (int)(10·64) = 640 (B+0xF8).
    public let M: Int
    /// Fresh samples per FFT: (int)(N − (10/30)·N), computed in float like the engine.
    public let fill: Int
    /// `audioinputvolume × 0.02` (B+0x0C).
    public var gain: Float
    /// `audioinputthreshold × 0.001` (B+0x10).
    public var threshold: Float

    static let exponent: Float = 0.25   // B+0xE4
    static let tilt: Float = 0.501      // B+0xE8 (0x3F004189)

    private var reL: [Float], imL: [Float], reR: [Float], imR: [Float]
    private var outRe: [Float], outIm: [Float]
    private let dft: ComplexDFT
    private var pos = 0
    private var silent = false
    private var idleMs: Float = 0
    private var stereo = false

    public init(sampleRate: Double, gain: Float = 1, threshold: Float = 0) {
        self.sampleRate = sampleRate
        self.gain = gain
        self.threshold = threshold
        let ratio = max(Float(sampleRate) / 44100, 1)
        N = Int(ratio * 64 * 30)
        M = Int(Float(10) * 64)
        let n = Float(N)
        fill = Int(n - (Float(10) / Float(30)) * n)
        // Buffers start at (127, 1/127); fill..N-1 are never written again and act as padding.
        reL = [Float](repeating: 127, count: N)
        imL = [Float](repeating: 1 / 127, count: N)
        reR = reL; imR = imL
        outRe = [Float](repeating: 0, count: N)
        outIm = outRe
        dft = ComplexDFT(n: N)
    }

    /// One iteration of the thread loop: the packets that arrived during `periodMs`.
    /// Returns the new 128-float spectrum when one is published (FFT done or silence), else nil.
    public func poll(_ packets: [AudioPacket], periodMs: Int) -> [Float]? {
        var thresholdSilent = false
        if packets.isEmpty {
            // 0x1400d14ac: compare first, then accumulate.
            if idleMs > 1000 { silent = true } else { idleMs += Float(periodMs) }
        } else {
            idleMs = 0
        }
        for p in packets {
            if thresholdSilent || p.silent { silent = true; continue }
            silent = false
            let frames = p.frames
            guard frames > 0, pos < N else { continue }
            let end = min(fill, pos + frames)
            let ch = p.channels
            p.samples.withUnsafeBufferPointer { s in
                var j = 0
                for i in pos..<end {
                    let x = s[j * ch] * 127 + 127
                    reL[i] = x; imL[i] = 1 / x
                    if ch >= 2 {
                        let y = s[j * ch + 1] * 127 + 127
                        reR[i] = y; imR[i] = 1 / y
                    }
                    j += 1
                }
                if threshold > 1.19209e-07 {
                    var mx: Float = 0
                    for j in 0..<(end - pos) { mx = max(s[j * ch], mx) }
                    if threshold > mx { thresholdSilent = true; silent = true }
                }
            }
            stereo = ch >= 2
            pos = end
        }
        if silent {
            pos = 0
            return [Float](repeating: 0, count: 128)
        }
        guard pos == fill else { return nil }
        pos = 0
        return analyse()
    }

    /// FFT + band mapping + scaling (0x1400d1b74–0x1400d1df6).
    func analyse() -> [Float] {
        var bins = [[Float]](repeating: [Float](repeating: 0, count: 64), count: 2)
        let channels = stereo ? 2 : 1
        let mm1 = Float(M - 1)
        let invM1 = 1 / mm1
        for ch in 0..<channels {
            if ch == 0 { dft.forward(reL, imL, &outRe, &outIm) } else { dft.forward(reR, imR, &outRe, &outIm) }
            var prev = 0
            for k in 1..<M {
                var p = outRe[k] * outRe[k] + outIm[k] * outIm[k]
                if !p.isFinite { p = 0 }
                let t = Float(k - 1)
                var b = Int(powf(t / mm1, Self.exponent) * 64) % 64
                if b < 0 { b += 64 }
                b = min(b, prev + 1)
                prev = b
                let v = p * (Self.tilt - (1 - Self.tilt) * cosf(t * .pi * invM1))
                bins[ch][b] = max(bins[ch][b], sqrtf(v))
            }
        }
        let scale = gain * 0.001 * (Float(M) / (Float(N) * 0.5))
        var out = [Float](repeating: 0, count: 128)
        for i in 0..<64 {
            out[i] = bins[0][i] * scale
            out[64 + i] = (channels >= 2 ? bins[1][i] : bins[0][i]) * scale
        }
        return out
    }
}

// MARK: - Per-frame normalisation (docs/re/06 §5.3, inside `Wallpaper_Frame` 0x140110630)

/// The six `g_AudioSpectrum*` arrays (uniform ids 0x62–0x67) plus the mono set.
public struct AudioSpectrumArrays {
    public var left16 = [Float](repeating: 0, count: 16), right16 = [Float](repeating: 0, count: 16)
    public var left32 = [Float](repeating: 0, count: 32), right32 = [Float](repeating: 0, count: 32)
    public var left64 = [Float](repeating: 0, count: 64), right64 = [Float](repeating: 0, count: 64)
    public var mono16 = [Float](repeating: 0, count: 16), mono32 = [Float](repeating: 0, count: 32)
    public var mono64 = [Float](repeating: 0, count: 64)

    public init() {}

    public var uniforms: [String: UniformValue] {
        ["g_AudioSpectrum16Left": .floats(left16), "g_AudioSpectrum16Right": .floats(right16),
         "g_AudioSpectrum32Left": .floats(left32), "g_AudioSpectrum32Right": .floats(right32),
         "g_AudioSpectrum64Left": .floats(left64), "g_AudioSpectrum64Right": .floats(right64)]
    }
}

/// Auto-gain and smoothing state. One per renderer; `update` runs once per frame.
public final class AudioSpectrumSmoother {
    private var A = [Float](repeating: 0, count: 128)   // +0x1A8
    private var B = [Float](repeating: 0, count: 128)   // +0x1A0
    private var level = [Float](repeating: 0, count: 16) // +0x1B0
    public private(set) var arrays = AudioSpectrumArrays()
    /// Mic-device flag (bit0): skips steps 1–4. Never set by the loopback backends.
    public var rawInput = false

    public init() {}

    /// `audioprocessing` off: the renderer's three arrays are zeroed (0x140115403–0x14011543a); the smoothing state
    /// (+0x1A0/+0x1A8/+0x1B0) is left alone.
    public func reset() { arrays = AudioSpectrumArrays() }

    /// `input`: the 128-float spectrum. `dt`: frame dt × timeScale × fade.
    public func update(input: [Float], dt frameDt: Float) {
        guard input.count >= 128 else { return }
        let dtA = min(max(frameDt, 0.0001), 0.25)
        var out = [Float](repeating: 0, count: 128)
        if rawInput {
            for i in 0..<128 { out[i] = input[i] }
        } else {
            // 1. Group maxima with the 0.333·max floor.
            var G = [Float](repeating: 0, count: 16)
            for g in 0..<16 {
                var m: Float = 0
                for i in 0..<8 { m = max(m, input[8 * g + i]) }
                G[g] = m
            }
            let mx = G.max() ?? 0
            for g in 0..<16 { G[g] = max(G[g], 0.333 * mx) }
            // 2. Level follows G: rising 1/s, falling 0.5/s.
            if mx >= 0.0001 && level[0] <= 0.0001 { for g in 0..<16 { level[g] = 1 } }
            for g in 0..<16 {
                let d = G[g] - level[g]
                if abs(d) > 0.0001 {
                    level[g] += min(dtA, abs(d)) * (d > 0 ? 1 : -0.5)
                } else {
                    level[g] = G[g]
                }
            }
            // 3. The engine uses rcpps (~12-bit); an exact reciprocal differs by < 0.04%.
            var inv = [Float](repeating: 0, count: 16)
            for g in 0..<16 { inv[g] = 1 / max(level[g], 0.001) }
            // 4. Lerp then slew limit.
            if mx >= 0.0001 {
                let k = min(20 * dtA, 1)
                let lo = max(-40 * dtA, -1), hi = min(40 * dtA, 1)
                for i in 0..<128 {
                    A[i] += (input[i] * inv[i / 8] - A[i]) * k
                    let delta = min(max(A[i] - B[i], lo), hi)
                    out[i] = B[i] + delta
                    B[i] = out[i]
                }
            }
        }
        // 5–6. Mono and the 32/16 pairwise maxima.
        var a = AudioSpectrumArrays()
        for i in 0..<64 {
            a.left64[i] = out[i]
            a.right64[i] = out[64 + i]
            a.mono64[i] = (out[i] + out[64 + i]) * 0.5
        }
        func halve(_ x: [Float]) -> [Float] { (0..<(x.count / 2)).map { max(x[2 * $0], x[2 * $0 + 1]) } }
        a.left32 = halve(a.left64); a.right32 = halve(a.right64); a.mono32 = halve(a.mono64)
        a.left16 = halve(a.left32); a.right16 = halve(a.right32); a.mono16 = halve(a.mono32)
        arrays = a
    }
}

// MARK: - FFT

/// Forward complex DFT X[k] = Σ x[n]·e^(−2πikn/N) for any N. Uses vDSP's DFT when N = f·2^k
/// (f ∈ {1,3,5,15}), otherwise Bluestein over a power-of-two vDSP FFT (the engine's ffts also
/// switches to Bluestein for such lengths).
final class ComplexDFT {
    let n: Int
    private var dftSetup: vDSP_DFT_Setup?
    // Bluestein state (double precision: the 127 offset puts a ~127·N DC term next to small bins)
    private var log2L: vDSP_Length = 0
    private var L = 0
    private var fftSetup: FFTSetupD?
    private var chirpRe: [Double] = [], chirpIm: [Double] = []   // w[n] = e^(−iπn²/N)
    private var kernelRe: [Double] = [], kernelIm: [Double] = [] // FFT of conj(w), wrapped
    private var aRe: [Double] = [], aIm: [Double] = []

    init(n: Int, forceBluestein: Bool = false) {
        self.n = n
        if !forceBluestein, let s = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD) {
            dftSetup = s
            return
        }
        var l = 1, lg: vDSP_Length = 0
        while l < 2 * n - 1 { l <<= 1; lg += 1 }
        L = l; log2L = lg
        fftSetup = vDSP_create_fftsetupD(lg, FFTRadix(kFFTRadix2))
        chirpRe = [Double](repeating: 0, count: n); chirpIm = chirpRe
        let twoN = 2 * n
        for i in 0..<n {
            // n² mod 2N in integers keeps the phase exact for large n.
            let q = (i * i) % twoN
            let ang = -Double.pi * Double(q) / Double(n)
            chirpRe[i] = cos(ang); chirpIm[i] = sin(ang)
        }
        kernelRe = [Double](repeating: 0, count: l); kernelIm = kernelRe
        for i in 0..<n {
            kernelRe[i] = chirpRe[i]; kernelIm[i] = -chirpIm[i]
            if i > 0 { kernelRe[l - i] = chirpRe[i]; kernelIm[l - i] = -chirpIm[i] }
        }
        fft(&kernelRe, &kernelIm, FFTDirection(kFFTDirection_Forward))
        aRe = [Double](repeating: 0, count: l); aIm = aRe
    }

    deinit {
        if let s = dftSetup { vDSP_DFT_DestroySetup(s) }
        if let s = fftSetup { vDSP_destroy_fftsetupD(s) }
    }

    private func fft(_ re: inout [Double], _ im: inout [Double], _ dir: FFTDirection) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var sc = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zipD(fftSetup!, &sc, 1, log2L, dir)
            }
        }
    }

    func forward(_ inRe: [Float], _ inIm: [Float], _ outRe: inout [Float], _ outIm: inout [Float]) {
        if let s = dftSetup {
            vDSP_DFT_Execute(s, inRe, inIm, &outRe, &outIm)
            return
        }
        for i in 0..<L { aRe[i] = 0; aIm[i] = 0 }
        for i in 0..<n {
            let xr = Double(inRe[i]), xi = Double(inIm[i])
            aRe[i] = xr * chirpRe[i] - xi * chirpIm[i]
            aIm[i] = xr * chirpIm[i] + xi * chirpRe[i]
        }
        fft(&aRe, &aIm, FFTDirection(kFFTDirection_Forward))
        for i in 0..<L {
            let r = aRe[i] * kernelRe[i] - aIm[i] * kernelIm[i]
            let m = aRe[i] * kernelIm[i] + aIm[i] * kernelRe[i]
            aRe[i] = r; aIm[i] = m
        }
        fft(&aRe, &aIm, FFTDirection(kFFTDirection_Inverse))
        let s = 1 / Double(L)
        for k in 0..<n {
            let r = aRe[k] * s, m = aIm[k] * s
            outRe[k] = Float(r * chirpRe[k] - m * chirpIm[k])
            outIm[k] = Float(r * chirpIm[k] + m * chirpRe[k])
        }
    }
}
