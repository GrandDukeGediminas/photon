import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Copies an AudioBufferList (interleaved or planar float32) into an interleaved packet.
/// `from`: index of the first buffer that belongs to the source (skips other streams of an aggregate).
func makePacket(_ abl: UnsafeMutableAudioBufferListPointer, frames hint: Int?, from: Int = 0) -> AudioPacket? {
    guard abl.count > from, let first = abl[from].mData else { return nil }
    if abl[from].mNumberChannels > 1 || abl.count == from + 1 {
        let ch = max(Int(abl[from].mNumberChannels), 1)
        let frames = hint ?? Int(abl[from].mDataByteSize) / (4 * ch)
        guard frames > 0 else { return nil }
        return makePacket(interleaved: first.assumingMemoryBound(to: Float.self), frames: frames, channels: ch)
    }
    let ch = min(abl.count - from, 2)
    let frames = hint ?? Int(abl[from].mDataByteSize) / 4
    guard frames > 0 else { return nil }
    var s = [Float](repeating: 0, count: frames * ch)
    for c in 0..<ch {
        guard let p = abl[from + c].mData?.assumingMemoryBound(to: Float.self) else { continue }
        let n = min(frames, Int(abl[from + c].mDataByteSize) / 4)
        for j in 0..<n { s[j * ch + c] = p[j] }
    }
    return AudioPacket(samples: s, channels: ch, silent: !s.contains { $0 != 0 })
}

// MARK: - Core Audio process tap (macOS 14.2+)

enum AudioCaptureError: Error, CustomStringConvertible {
    case status(String, OSStatus)
    case unsupported(String)
    var description: String {
        switch self {
        case .status(let what, let s): return "\(what) failed (OSStatus \(s))"
        case .unsupported(let s): return s
        }
    }
}

private func check(_ s: OSStatus, _ what: String) throws {
    if s != noErr { throw AudioCaptureError.status(what, s) }
}

private func getProperty<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                            qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0) -> OSStatus {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, qualifierSize, qualifier, &size, &value)
}

/// Global stereo tap of every process except ours, read through a private aggregate device.
@available(macOS 14.2, *)
final class ProcessTapCapture: AudioCaptureBackend {
    let name = "Core Audio process tap"
    private(set) var sampleRate: Double = 48000
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "photon.audio.tap", qos: .userInteractive)

    init(queue: AudioPacketQueue) throws {
        // Our own process object, if Core Audio knows it, is excluded from the tap.
        var pid = getpid()
        var own = AudioObjectID(kAudioObjectUnknown)
        _ = getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyTranslatePIDToProcessObject, &own,
                        qualifier: &pid, qualifierSize: UInt32(MemoryLayout<pid_t>.size))
        let exclude: [AudioObjectID] = own != kAudioObjectUnknown ? [own] : []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.uuid = UUID()
        desc.name = "photon spectrum tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        do {
            try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")

            var fmt = AudioStreamBasicDescription()
            try check(getProperty(tapID, kAudioTapPropertyFormat, &fmt), "kAudioTapPropertyFormat")
            guard fmt.mFormatID == kAudioFormatLinearPCM, fmt.mBitsPerChannel == 32,
                  fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw AudioCaptureError.unsupported("tap format is not float32") // engine: "requires 32 bit per sample"
            }
            sampleRate = fmt.mSampleRate

            var outputDevice = AudioObjectID(kAudioObjectUnknown)
            try check(getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, &outputDevice),
                      "default output device")
            var uid: Unmanaged<CFString>?
            try check(getProperty(outputDevice, kAudioDevicePropertyDeviceUID, &uid), "output device UID")
            let outputUID = (uid?.takeRetainedValue() as String?) ?? ""

            // The aggregate lists the main sub-device's input streams before the tap's.
            var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                         mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(outputDevice, &streamsAddr, 0, nil, &streamsSize)
            let tapIndex = Int(streamsSize) / MemoryLayout<AudioStreamID>.size

            let dict: [String: Any] = [
                kAudioAggregateDeviceNameKey: "photon audio tap",
                kAudioAggregateDeviceUIDKey: "photon.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                                   kAudioSubTapUIDKey: desc.uuid.uuidString]],
            ]
            try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID), "AudioHardwareCreateAggregateDevice")

            let debug = ProcessInfo.processInfo.environment["PHOTON_AUDIO_DEBUG"] != nil
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
                let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                if debug {
                    let desc = abl.map { b -> String in
                        let n = Int(b.mDataByteSize) / 4
                        let p = b.mData?.assumingMemoryBound(to: Float.self)
                        var mx: [Float] = Array(repeating: 0, count: Int(b.mNumberChannels))
                        if let p { for i in 0..<n { let c = i % max(mx.count, 1); mx[c] = max(mx[c], abs(p[i])) } }
                        return "\(b.mNumberChannels)ch \(b.mDataByteSize)B max \(mx)"
                    }
                    FileHandle.standardError.write("tap buffers: \(desc)\n".data(using: .utf8)!)
                }
                if let p = makePacket(abl, frames: nil, from: min(tapIndex, max(abl.count - 1, 0))) { queue.push(p) }
            }, "AudioDeviceCreateIOProcIDWithBlock")
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        procID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}

// MARK: - ScreenCaptureKit fallback (needs Screen Recording permission)

final class ScreenCaptureAudio: NSObject, AudioCaptureBackend, SCStreamOutput, SCStreamDelegate {
    let name = "ScreenCaptureKit"
    let sampleRate: Double = 48000
    private var stream: SCStream?
    private let queue: AudioPacketQueue
    private let sampleQueue = DispatchQueue(label: "photon.audio.sck", qos: .userInteractive)

    /// Starts asynchronously; `failed` is called once if the stream cannot start.
    init(queue: AudioPacketQueue, failed: @escaping (Error) -> Void) {
        self.queue = queue
        super.init()
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { throw AudioCaptureError.unsupported("no display") }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Int(sampleRate)
                config.channelCount = 2
                // Audio only: keep the mandatory video stream tiny and slow.
                config.width = 2; config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let s = SCStream(filter: filter, configuration: config, delegate: self)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await s.startCapture()
                self.stream = s
            } catch {
                failed(error)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        let frames = CMSampleBufferGetNumSamples(sb)
        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil,
                                                                bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer)
        guard st == noErr else { return }
        if let p = makePacket(UnsafeMutableAudioBufferListPointer(ablPtr), frames: frames) { queue.push(p) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AudioSystem.logOnce("photon: ScreenCaptureKit audio stopped: \(error.localizedDescription)")
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }
}

// MARK: - Backend selection (macOS)

extension AudioSystem {
    static let silenceHint = "photon: system audio capture has delivered only silence for 5 s (nothing playing, or "
        + "System Audio Recording permission denied in Privacy & Security)"

    /// The process tap (macOS 14.2+), else ScreenCaptureKit.
    func startPlatformBackend() {
        var tapError: Error?
        if #available(macOS 14.2, *) {
            do {
                let tap = try ProcessTapCapture(queue: packets)
                attach(tap)
                return
            } catch { tapError = error }
        }
        Self.logOnce("photon: process tap unavailable (\(tapError.map { "\($0)" } ?? "macOS < 14.2")), trying ScreenCaptureKit")
        let sck = ScreenCaptureAudio(queue: packets) { error in
            Self.logOnce("photon: system audio capture unavailable (\(error.localizedDescription)); audio spectrum stays zero")
        }
        attach(sck)
    }
}
