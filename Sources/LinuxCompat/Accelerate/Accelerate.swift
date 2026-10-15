// Linux stand-in for Apple's Accelerate (docs/linux-port.md §4): the vDSP DFT/FFT entry points AudioSpectrum.swift
// uses, with vDSP's conventions (forward X[k] = Σ x[n]·e^(−2πikn/N), inverse with e^(+…), both unscaled; split
// complex storage; vDSP_DFT_zop_CreateSetup accepts the same lengths as macOS and returns nil otherwise).
// Arithmetic is double precision throughout (Apple's float DFT works in float), so results agree with macOS to float
// rounding, not bit for bit.

import Foundation

public typealias vDSP_Length = UInt
public typealias vDSP_Stride = Int
public typealias FFTRadix = Int32
public typealias FFTDirection = Int32
public let kFFTRadix2: Int32 = 0
public let kFFTRadix3: Int32 = 1
public let kFFTRadix5: Int32 = 2
public let kFFTDirection_Forward: Int32 = 1
public let kFFTDirection_Inverse: Int32 = -1

public enum vDSP_DFT_Direction: Int32 {
    case FORWARD = 1
    case INVERSE = -1
}

public struct DSPSplitComplex {
    public var realp: UnsafeMutablePointer<Float>
    public var imagp: UnsafeMutablePointer<Float>
    public init(realp: UnsafeMutablePointer<Float>, imagp: UnsafeMutablePointer<Float>) { self.realp = realp; self.imagp = imagp }
}

public struct DSPDoubleSplitComplex {
    public var realp: UnsafeMutablePointer<Double>
    public var imagp: UnsafeMutablePointer<Double>
    public init(realp: UnsafeMutablePointer<Double>, imagp: UnsafeMutablePointer<Double>) { self.realp = realp; self.imagp = imagp }
}

/// Mixed-radix complex transform for N = f·2^k (radix-2 decimation in time down to an f-point direct DFT).
final class _ComplexTransform {
    let n: Int
    let odd: Int
    let cosT: [Double], sinT: [Double] // e^(−2πij/N) = cosT[j] − i·sinT[j]... stored as cos and sin of 2πj/N

    init(n: Int) {
        self.n = n
        var f = n
        while f % 2 == 0 && f > 1 { f /= 2 }
        odd = f
        var c = [Double](repeating: 0, count: n), s = c
        for j in 0..<n {
            let a = 2 * Double.pi * Double(j) / Double(n)
            c[j] = cos(a); s[j] = sin(a)
        }
        cosT = c; sinT = s
    }

    /// In-place transform of (re, im); `sign` −1 forward, +1 inverse.
    func run(_ re: inout [Double], _ im: inout [Double], sign: Double) {
        var outRe = [Double](repeating: 0, count: n), outIm = outRe
        rec(re, im, 0, 1, n, &outRe, &outIm, 0, sign)
        re = outRe; im = outIm
    }

    private func rec(_ re: [Double], _ im: [Double], _ start: Int, _ stride: Int, _ len: Int,
                     _ oRe: inout [Double], _ oIm: inout [Double], _ oStart: Int, _ sign: Double) {
        let step = n / len // twiddle index step for this length
        if len == odd {
            for k in 0..<len {
                var sr = 0.0, si = 0.0
                for j in 0..<len {
                    let t = (j * k % len) * step
                    let c = cosT[t], s = sign * sinT[t]
                    let xr = re[start + j * stride], xi = im[start + j * stride]
                    sr += xr * c - xi * s
                    si += xr * s + xi * c
                }
                oRe[oStart + k] = sr; oIm[oStart + k] = si
            }
            return
        }
        let half = len / 2
        rec(re, im, start, stride * 2, half, &oRe, &oIm, oStart, sign)
        rec(re, im, start + stride, stride * 2, half, &oRe, &oIm, oStart + half, sign)
        for k in 0..<half {
            let t = k * step
            let c = cosT[t], s = sign * sinT[t]
            let er = oRe[oStart + k], ei = oIm[oStart + k]
            let orr = oRe[oStart + half + k], oi = oIm[oStart + half + k]
            let tr = orr * c - oi * s, ti = orr * s + oi * c
            oRe[oStart + k] = er + tr; oIm[oStart + k] = ei + ti
            oRe[oStart + half + k] = er - tr; oIm[oStart + half + k] = ei - ti
        }
    }
}

public final class vDSP_DFT_SetupStruct {
    let transform: _ComplexTransform
    let direction: vDSP_DFT_Direction
    init(n: Int, direction: vDSP_DFT_Direction) {
        transform = _ComplexTransform(n: n)
        self.direction = direction
    }
}
public typealias vDSP_DFT_Setup = vDSP_DFT_SetupStruct

public func vDSP_DFT_zop_CreateSetup(_ previous: vDSP_DFT_Setup?, _ length: vDSP_Length, _ direction: vDSP_DFT_Direction) -> vDSP_DFT_Setup? {
    // The lengths macOS 15+ accepts (probed for 1…2000): 2^k; 3·2^k and 5·2^k for k ≥ 3; 15·2^k for k ≥ 2; 90; 180.
    var f = Int(length), k = 0
    guard f > 0 else { return nil }
    while f % 2 == 0 { f /= 2; k += 1 }
    let accepted = f == 1 || ((f == 3 || f == 5) && k >= 3) || (f == 15 && k >= 2) || (f == 45 && (k == 1 || k == 2))
    guard accepted else { return nil }
    return vDSP_DFT_SetupStruct(n: Int(length), direction: direction)
}

public func vDSP_DFT_DestroySetup(_ setup: vDSP_DFT_Setup?) {}

public func vDSP_DFT_Execute(_ setup: vDSP_DFT_Setup, _ ir: UnsafePointer<Float>, _ ii: UnsafePointer<Float>,
                             _ or: UnsafeMutablePointer<Float>, _ oi: UnsafeMutablePointer<Float>) {
    let n = setup.transform.n
    var re = (0..<n).map { Double(ir[$0]) }, im = (0..<n).map { Double(ii[$0]) }
    setup.transform.run(&re, &im, sign: setup.direction == .FORWARD ? -1 : 1)
    for k in 0..<n { or[k] = Float(re[k]); oi[k] = Float(im[k]) }
}

public final class OpaqueFFTSetupD {
    let maxLog2n: Int
    var transforms: [Int: _ComplexTransform] = [:]
    init(maxLog2n: Int) { self.maxLog2n = maxLog2n }
    func transform(_ log2n: Int) -> _ComplexTransform {
        if let t = transforms[log2n] { return t }
        let t = _ComplexTransform(n: 1 << log2n)
        transforms[log2n] = t
        return t
    }
}
public typealias FFTSetupD = OpaqueFFTSetupD

public func vDSP_create_fftsetupD(_ log2n: vDSP_Length, _ radix: FFTRadix) -> FFTSetupD? {
    guard radix == kFFTRadix2, log2n <= 30 else { return nil }
    return OpaqueFFTSetupD(maxLog2n: Int(log2n))
}

public func vDSP_destroy_fftsetupD(_ setup: FFTSetupD?) {}

/// In-place complex FFT of 2^log2n points, unscaled in both directions.
public func vDSP_fft_zipD(_ setup: FFTSetupD, _ c: UnsafePointer<DSPDoubleSplitComplex>, _ stride: vDSP_Stride,
                          _ log2n: vDSP_Length, _ direction: FFTDirection) {
    precondition(Int(log2n) <= setup.maxLog2n, "vDSP_fft_zipD: log2n exceeds the setup")
    let n = 1 << Int(log2n)
    let sc = c.pointee
    var re = (0..<n).map { sc.realp[$0 * stride] }, im = (0..<n).map { sc.imagp[$0 * stride] }
    setup.transform(Int(log2n)).run(&re, &im, sign: direction == kFFTDirection_Forward ? -1 : 1)
    for k in 0..<n { sc.realp[k * stride] = re[k]; sc.imagp[k * stride] = im[k] }
}
