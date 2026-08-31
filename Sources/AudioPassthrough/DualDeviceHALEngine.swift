import Foundation
import CoreAudio
import Atomics

/// Runs independent input and output IOProcs on two separate devices, bridged by
/// a lock-free ring buffer. No virtual/aggregate device is created. Because the
/// two devices run on different clocks, a small ring buffer plus fill-level
/// monitoring keeps drift bounded; latency is a bit above the aggregate engine.
final class DualDeviceHALEngine: PassthroughEngineProtocol {

    private var inputProcID: AudioDeviceIOProcID?
    private var outputProcID: AudioDeviceIOProcID?
    private var inputDevice: AudioDeviceID = 0
    private var outputDevice: AudioDeviceID = 0
    private var running = false

    private(set) var pinnedInputID: AudioDeviceID?

    var desiredSampleRate: Double?
    var desiredBufferFrames: UInt32?
    var onInputLostWarning: ((String) -> Void)?

    private var ring: RingBuffer?
    private var channels: Int = 2
    private var activeSampleRate: Double = 48_000

    // Peak level (0...1) written from the input IOProc, read by the app poll.
    private let peakLevel = ManagedAtomic<UInt32>(0)
    var currentPeakLevel: Float { Float(bitPattern: peakLevel.load(ordering: .relaxed)) }

    private let volumeBits = ManagedAtomic<UInt32>(Float(1.0).bitPattern)
    var volume: Float {
        get { Float(bitPattern: volumeBits.load(ordering: .relaxed)) }
        set { volumeBits.store(max(0, newValue).bitPattern, ordering: .relaxed) }
    }

    // Realtime-side scratch for deinterleave-free copy.
    private var floatScratch: UnsafeMutablePointer<Float>?
    private var scratchCount: Int = 0

    var isRunning: Bool { running }

    // MARK: - Control

    func start(inputDeviceID: AudioDeviceID) throws {
        stop()
        pinnedInputID = inputDeviceID
        inputDevice = inputDeviceID
        outputDevice = AudioDevices.defaultOutput()
        try buildAndStart()
    }

    func stop() {
        teardown()
        pinnedInputID = nil
    }

    func refresh() {
        guard let input = pinnedInputID else { return }
        teardown()
        pinnedInputID = input
        inputDevice = input
        outputDevice = AudioDevices.defaultOutput()

        // The output may not be valid yet (device still settling after a
        // connect/disconnect). Validate; if it's not usable, retry shortly.
        guard outputDevice != 0,
              AudioDevices.outputs().contains(where: { $0.id == outputDevice }) else {
            retryRefresh()
            return
        }

        do {
            try buildAndStart()
        } catch {
            // A transient failure (device mid-transition) — try once more soon.
            retryRefresh(afterError: "\(error)")
        }
    }

    private var refreshRetries = 0
    private func retryRefresh(afterError err: String? = nil) {
        guard refreshRetries < 3 else {
            refreshRetries = 0
            running = false
            onInputLostWarning?("Couldn’t rebind audio output after a device change." +
                                (err.map { " (\($0))" } ?? ""))
            return
        }
        refreshRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self, self.pinnedInputID != nil else { return }
            self.refresh()
        }
    }

    @discardableResult
    func setOutputDevice(_ id: AudioDeviceID) -> Bool {
        let ok = AudioDevices.setDefaultOutput(id)
        if ok { outputDevice = id } // pipeline refresh is driven by the output-change listener
        return ok
    }

    func setSampleRate(_ rate: Double) { desiredSampleRate = rate; if running { refresh() } }
    func setBufferFrames(_ frames: UInt32) { desiredBufferFrames = frames; if running { refresh() } }

    func applyPreset(_ preset: Preset) {
        let r = resolvePreset(preset)
        desiredSampleRate = r.rate
        desiredBufferFrames = r.frames
        if running { refresh() }
    }

    func handleInputChanged() {
        guard running, let pinned = pinnedInputID else { return }
        if !AudioDevices.inputs().contains(where: { $0.id == pinned }) {
            onInputLostWarning?("Your line-in input was disconnected.")
            stop()
        }
    }

    // MARK: - Build / teardown

    private func teardown() {
        // Devices may already be gone (e.g. AirPods disconnected), so these
        // calls can fail — ignore errors and always clear state fully.
        if let id = inputProcID {
            AudioDeviceStop(inputDevice, id)
            AudioDeviceDestroyIOProcID(inputDevice, id)
            inputProcID = nil
        }
        if let id = outputProcID {
            AudioDeviceStop(outputDevice, id)
            AudioDeviceDestroyIOProcID(outputDevice, id)
            outputProcID = nil
        }
        ring = nil
        floatScratch?.deallocate(); floatScratch = nil; scratchCount = 0
        running = false
    }

    private func buildAndStart() throws {
        let rate = desiredSampleRate ?? AudioDevices.nominalSampleRate(inputDevice)
        activeSampleRate = rate > 0 ? rate : 48_000
        if desiredSampleRate != nil {
            AudioDevices.setNominalSampleRate(inputDevice, rate)
            AudioDevices.setNominalSampleRate(outputDevice, rate)
        }
        if let frames = desiredBufferFrames {
            AudioDevices.setBufferFrameSize(inputDevice, frames)
            AudioDevices.setBufferFrameSize(outputDevice, frames)
        }

        channels = max(1, channelCount(outputDevice))
        let bufFrames = Int(desiredBufferFrames ?? 512)
        // Ring holds ~4 buffers of slack to absorb clock drift between devices.
        ring = RingBuffer(capacityFrames: bufFrames * 8, channels: channels)

        scratchCount = bufFrames * channels * 4
        floatScratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCount)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // --- Input IOProc: writes captured frames into the ring ---
        var inID: AudioDeviceIOProcID?
        try osCheck(AudioDeviceCreateIOProcID(inputDevice, inputIOProc, selfPtr, &inID),
                    "create input IOProc")
        inputProcID = inID

        // --- Output IOProc: reads from ring into the output buffer ---
        var outID: AudioDeviceIOProcID?
        try osCheck(AudioDeviceCreateIOProcID(outputDevice, outputIOProc, selfPtr, &outID),
                    "create output IOProc")
        outputProcID = outID

        try osCheck(AudioDeviceStart(inputDevice, inID), "start input")
        try osCheck(AudioDeviceStart(outputDevice, outID), "start output")
        running = true
        refreshRetries = 0
    }

    // MARK: - Realtime entry points (called from the C IOProcs)

    fileprivate func handleInput(_ inData: UnsafePointer<AudioBufferList>) {
        guard let ring = ring else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
        guard let buf = abl.first, let data = buf.mData else { return }
        let sampleCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        let ptr = data.assumingMemoryBound(to: Float.self)
        ring.write(ptr, count: sampleCount)

        // Track peak magnitude for idle detection (cheap, realtime-safe).
        // Use peak-hold with time-based decay: brief dips between words/beats must
        // not read as silence, so we keep the recent max and let it fall off over
        // roughly a second of true silence (independent of buffer size).
        var peak: Float = 0
        for i in 0..<sampleCount {
            let m = abs(ptr[i])
            if m > peak { peak = m }
        }
        // Per-buffer decay derived from sample count: ~-6 dB over ~0.4 s of silence.
        // dt = frames/rate; decay = exp(-dt / tau), tau ≈ 0.6 s.
        let frames = Float(sampleCount / max(1, channels))
        let rate = Float(activeSampleRate)
        let dt = frames / rate
        let decay = exp(-dt / 0.6)
        let held = Float(bitPattern: peakLevel.load(ordering: .relaxed))
        let newPeak = max(peak, held * decay)
        peakLevel.store(newPeak.bitPattern, ordering: .relaxed)
    }

    fileprivate func handleOutput(_ outData: UnsafeMutablePointer<AudioBufferList>) {
        guard let ring = ring else { return }
        let abl = UnsafeMutableAudioBufferListPointer(outData)
        guard let buf = abl.first, let data = buf.mData else { return }
        let sampleCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        let ptr = data.assumingMemoryBound(to: Float.self)
        ring.read(into: ptr, count: sampleCount)

        // Apply gain unless it's unity.
        let g = volume
        if g != 1.0 {
            for i in 0..<sampleCount { ptr[i] *= g }
        }
    }

    // MARK: - Helpers

    private func channelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 2 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 2 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    enum EngineError: Error { case os(OSStatus, String) }
    private func osCheck(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw EngineError.os(status, what) }
    }
}

// MARK: - C IOProcs (no Swift captures allowed)

private func inputIOProc(_ device: AudioObjectID,
                         _ now: UnsafePointer<AudioTimeStamp>,
                         _ inData: UnsafePointer<AudioBufferList>,
                         _ inTime: UnsafePointer<AudioTimeStamp>,
                         _ outData: UnsafeMutablePointer<AudioBufferList>,
                         _ outTime: UnsafePointer<AudioTimeStamp>,
                         _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let ctx = clientData else { return noErr }
    let engine = Unmanaged<DualDeviceHALEngine>.fromOpaque(ctx).takeUnretainedValue()
    engine.handleInput(inData)
    return noErr
}

private func outputIOProc(_ device: AudioObjectID,
                          _ now: UnsafePointer<AudioTimeStamp>,
                          _ inData: UnsafePointer<AudioBufferList>,
                          _ inTime: UnsafePointer<AudioTimeStamp>,
                          _ outData: UnsafeMutablePointer<AudioBufferList>,
                          _ outTime: UnsafePointer<AudioTimeStamp>,
                          _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let ctx = clientData else { return noErr }
    let engine = Unmanaged<DualDeviceHALEngine>.fromOpaque(ctx).takeUnretainedValue()
    engine.handleOutput(outData)
    return noErr
}
