import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

enum AudioDevices {

    // MARK: - Enumeration

    static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &dataSize) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &dataSize, &ids) == noErr else { return [] }

        return ids.compactMap { device(for: $0) }
    }

    static func device(for id: AudioDeviceID) -> AudioDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioDevice(id: id, uid: uid, name: name,
                           hasInput: channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0,
                           hasOutput: channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0)
    }

    static func inputs() -> [AudioDevice] { all().filter { $0.hasInput } }
    static func outputs() -> [AudioDevice] { all().filter { $0.hasOutput } }

    // MARK: - Default device get/set

    static func defaultInput() -> AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }
    static func defaultOutput() -> AudioDeviceID { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, id)
    }

    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, id)
    }

    private static func setDefaultDevice(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &addr, 0, nil, size, &dev) == noErr
    }

    // MARK: - Sample rate

    /// Nominal sample rates a device advertises (e.g. 44100, 48000, 96000).
    static func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        // Expand ranges to discrete points; most devices report min==max per entry.
        var rates = Set<Double>()
        for r in ranges { rates.insert(r.mMinimum); rates.insert(r.mMaximum) }
        return rates.sorted()
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    @discardableResult
    static func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var r = rate
        let size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, size, &r) == noErr
    }

    // MARK: - Buffer size (frames)

    static func bufferFrameSize(_ id: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &frames)
        return frames
    }

    static func bufferFrameSizeRange(_ id: AudioDeviceID) -> ClosedRange<UInt32>? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &range) == noErr else { return nil }
        return UInt32(range.mMinimum)...UInt32(range.mMaximum)
    }

    @discardableResult
    static func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var f = frames
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, size, &f) == noErr
    }

    // MARK: - Change listeners

    /// Adds a system-object listener for default input OR output device changes.
    static func addDefaultDeviceListener(selector: AudioObjectPropertySelector,
                                         queue: DispatchQueue,
                                         handler: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        return block
    }

    static func removeDefaultDeviceListener(selector: AudioObjectPropertySelector,
                                            queue: DispatchQueue,
                                            block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
    }

    // MARK: - Property helpers

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let bufList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { bufList.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufList) == noErr else { return 0 }
        let abl = bufList.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfStr) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return cfStr as String?
    }
}
