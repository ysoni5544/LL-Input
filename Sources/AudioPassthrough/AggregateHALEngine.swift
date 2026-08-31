import Foundation
import CoreAudio
import AudioToolbox
import Atomics

/// Lowest-latency engine. Wraps input+output in a private aggregate device and
/// runs a single HAL AudioUnit whose render callback pulls input and writes it
/// straight to output in the same pass — no mixer graph, no cross-device drift.
final class AggregateHALEngine: PassthroughEngineProtocol {

    private var audioUnit: AudioUnit?
    private var aggregateID: AudioDeviceID = 0
    private var running = false

    private(set) var pinnedInputID: AudioDeviceID?
    private var currentOutputID: AudioDeviceID = 0
    private var activeSampleRate: Double = 48_000

    var desiredSampleRate: Double?
    var desiredBufferFrames: UInt32?
    var onInputLostWarning: ((String) -> Void)?

    // Buffer that holds pulled input frames each render cycle.
    private var inputBufferList: UnsafeMutableAudioBufferListPointer?
    private var inputScratch: UnsafeMutableRawPointer?
    private var scratchByteCapacity: Int = 0

    private let peakLevel = ManagedAtomic<UInt32>(0)
    var currentPeakLevel: Float { Float(bitPattern: peakLevel.load(ordering: .relaxed)) }

    private let volumeBits = ManagedAtomic<UInt32>(Float(1.0).bitPattern)
    var volume: Float {
        get { Float(bitPattern: volumeBits.load(ordering: .relaxed)) }
        set { volumeBits.store(max(0, newValue).bitPattern, ordering: .relaxed) }
    }
    fileprivate var gain: Float { volume }

    var isRunning: Bool { running }

    // MARK: - Control

    func start(inputDeviceID: AudioDeviceID) throws {
        stop()
        pinnedInputID = inputDeviceID
        currentOutputID = AudioDevices.defaultOutput()
        try buildAndStart()
    }

    func stop() {
        if let au = audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
        if aggregateID != 0 {
            AggregateDevice.destroy(aggregateID)
            aggregateID = 0
        }
        freeScratch()
        running = false
    }

    func refresh() {
        guard pinnedInputID != nil else { return }
        let input = pinnedInputID!
        stopKeepingSelection()
        pinnedInputID = input
        currentOutputID = AudioDevices.defaultOutput()

        guard currentOutputID != 0,
              AudioDevices.outputs().contains(where: { $0.id == currentOutputID }) else {
            retryRefresh()
            return
        }
        do {
            try buildAndStart()
            refreshRetries = 0
        } catch {
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
        if ok { currentOutputID = id } // pipeline refresh is driven by the output-change listener
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
        // The aggregate owns the input sub-device, so a system default change
        // doesn't affect us — but if the pinned device vanished, warn.
        if !AudioDevices.inputs().contains(where: { $0.id == pinned }) {
            onInputLostWarning?("Your line-in input was disconnected.")
            stop()
        }
    }

    // MARK: - Build

    private func stopKeepingSelection() {
        if let au = audioUnit {
            AudioOutputUnitStop(au); AudioUnitUninitialize(au); AudioComponentInstanceDispose(au)
            audioUnit = nil
        }
        if aggregateID != 0 { AggregateDevice.destroy(aggregateID); aggregateID = 0 }
        freeScratch()
        running = false
    }

    private func buildAndStart() throws {
        guard let inputID = pinnedInputID,
              let inUID = AudioDevices.device(for: inputID)?.uid,
              let outUID = AudioDevices.device(for: currentOutputID)?.uid else {
            throw EngineError.deviceUnavailable
        }

        let rate = desiredSampleRate ?? AudioDevices.nominalSampleRate(inputID)
        activeSampleRate = rate > 0 ? rate : 48_000

        // Master clock = input, so output drift-compensates to the line-in.
        guard let agg = AggregateDevice.create(inputUID: inUID, outputUID: outUID,
                                               masterUID: inUID, sampleRate: rate) else {
            throw EngineError.aggregateCreateFailed
        }
        aggregateID = agg

        if let frames = desiredBufferFrames {
            AudioDevices.setBufferFrameSize(agg, frames)
        }

        // --- Instantiate a HAL output AudioUnit bound to the aggregate ---
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw EngineError.noHALUnit }
        var au: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &au), "instantiate HAL unit")
        guard let unit = au else { throw EngineError.noHALUnit }
        audioUnit = unit

        // Enable input (bus 1) and output (bus 0).
        var enable: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)),
                  "enable input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size)),
                  "enable output")

        // Bind the aggregate as the unit's current device.
        var dev = aggregateID
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)),
                  "set current device")

        // Match stream format on both buses to the input's hardware format.
        var fmt = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 1, &fmt, &fmtSize),
                  "get input format")
        fmt.mSampleRate = rate
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, 1, &fmt, fmtSize),
                  "set input-scope output format")
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &fmt, fmtSize),
                  "set output-scope input format")

        // Allocate scratch buffers for pulling input each cycle.
        allocateScratch(channels: Int(fmt.mChannelsPerFrame),
                        bytesPerFrame: Int(fmt.mBytesPerFrame),
                        maxFrames: Int(desiredBufferFrames ?? 512))

        // Install the render callback.
        var cb = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "set render callback")

        try check(AudioUnitInitialize(unit), "initialize unit")
        try check(AudioOutputUnitStart(unit), "start unit")
        running = true
    }

    // MARK: - Scratch buffers

    private func allocateScratch(channels: Int, bytesPerFrame: Int, maxFrames: Int) {
        freeScratch()
        let bytes = max(bytesPerFrame, 4) * max(maxFrames, 64)
        scratchByteCapacity = bytes
        inputScratch = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        abl[0] = AudioBuffer(mNumberChannels: UInt32(max(channels, 1)),
                             mDataByteSize: UInt32(bytes),
                             mData: inputScratch)
        inputBufferList = abl
    }

    private func freeScratch() {
        inputScratch?.deallocate(); inputScratch = nil
        if let abl = inputBufferList { free(abl.unsafeMutablePointer) }
        inputBufferList = nil
        scratchByteCapacity = 0
    }

    // Accessed from the realtime callback.
    fileprivate var unitRef: AudioUnit? { audioUnit }

    fileprivate func pullInput(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               timestamp: UnsafePointer<AudioTimeStamp>,
                               frames: UInt32,
                               into abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let unit = audioUnit else { return kAudioUnitErr_Uninitialized }
        return AudioUnitRender(unit, flags, timestamp, 1, frames, abl)
    }

    fileprivate var scratchList: UnsafeMutableAudioBufferListPointer? { inputBufferList }

    /// Store an instantaneous buffer peak using peak-hold with time-based decay,
    /// so brief dips between words/beats don't read as silence for idle detection.
    fileprivate func storePeak(_ p: Float, frames: Int) {
        let rate = Float(activeSampleRate > 0 ? activeSampleRate : 48_000)
        let dt = Float(max(1, frames)) / rate
        let decay = exp(-dt / 0.6)
        let held = Float(bitPattern: peakLevel.load(ordering: .relaxed))
        let newPeak = max(p, held * decay)
        peakLevel.store(newPeak.bitPattern, ordering: .relaxed)
    }

    enum EngineError: Error { case deviceUnavailable, aggregateCreateFailed, noHALUnit, os(OSStatus, String) }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw EngineError.os(status, what) }
    }
}

// MARK: - Realtime render callback (C function, no captures)

private func renderCallback(inRefCon: UnsafeMutableRawPointer,
                            ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            inTimeStamp: UnsafePointer<AudioTimeStamp>,
                            inBusNumber: UInt32,
                            inNumberFrames: UInt32,
                            ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {

    let engine = Unmanaged<AggregateHALEngine>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let outData = ioData, let scratch = engine.scratchList else { return noErr }

    // Point our scratch buffer list at the right size for this cycle.
    let bytesNeeded = Int(inNumberFrames) * Int(outData.pointee.mBuffers.mNumberChannels) * MemoryLayout<Float>.size
    scratch[0].mDataByteSize = UInt32(bytesNeeded)

    // Pull input into scratch.
    let status = engine.pullInput(flags: ioActionFlags, timestamp: inTimeStamp,
                                  frames: inNumberFrames, into: scratch.unsafeMutablePointer)
    if status != noErr {
        // On underrun, output silence rather than glitching hard.
        let out = UnsafeMutableAudioBufferListPointer(outData)
        for buf in out { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
        return noErr
    }

    // Copy scratch -> output buffers.
    let out = UnsafeMutableAudioBufferListPointer(outData)
    let copyBytes = min(Int(scratch[0].mDataByteSize), Int(out[0].mDataByteSize))
    if let src = scratch[0].mData, let dst = out[0].mData {
        let count = copyBytes / MemoryLayout<Float>.size
        let sp = src.assumingMemoryBound(to: Float.self)
        let dp = dst.assumingMemoryBound(to: Float.self)
        let g = engine.gain
        var peak: Float = 0
        if g == 1.0 {
            memcpy(dst, src, copyBytes)
            for i in 0..<count { let m = abs(sp[i]); if m > peak { peak = m } }
        } else {
            for i in 0..<count { let v = sp[i] * g; dp[i] = v; let m = abs(v); if m > peak { peak = m } }
        }
        let channels = Int(outData.pointee.mBuffers.mNumberChannels)
        engine.storePeak(peak, frames: count / max(1, channels))
    }
    return noErr
}
