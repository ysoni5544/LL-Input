import Foundation
import CoreAudio

/// One-click modes: pick an engine, sample rate, and buffer size together.
enum Preset: Equatable {
    case game      // Dual-Device HAL, 48k, 256 frames
    case stereo    // auto-pick best settings for stereo speakers
    case ultra     // Dual-Device HAL, 48k, 64 frames (lowest latency)
    case custom    // changes nothing — keeps whatever is currently set

    var title: String {
        switch self {
        case .game:   return "Game Mode"
        case .stereo: return "Stereo Mode"
        case .ultra:  return "Ultra Latency Mode"
        case .custom: return "Custom"
        }
    }

    /// Custom applies no settings; the app skips applyPreset for it.
    var changesSettings: Bool { self != .custom }

    var sampleRate: Double { 48_000 }

    /// nil = let the app choose the best buffer for the current device.
    var bufferFrames: UInt32? {
        switch self {
        case .game:   return 256
        case .stereo: return nil
        case .ultra:  return 64
        case .custom: return nil
        }
    }

    /// nil = keep the currently selected engine.
    var engine: EngineKind? {
        switch self {
        case .game:   return .dualDeviceHAL
        case .stereo: return nil
        case .ultra:  return .dualDeviceHAL
        case .custom: return nil
        }
    }
}

/// Which passthrough backend is active.
enum EngineKind: String, CaseIterable {
    case avAudioEngine
    case aggregateHAL
    case dualDeviceHAL

    var title: String {
        switch self {
        case .avAudioEngine: return "AVAudioEngine"
        case .aggregateHAL:  return "Aggregate HAL (lowest latency)"
        case .dualDeviceHAL: return "Dual-Device HAL"
        }
    }

    var detail: String {
        switch self {
        case .avAudioEngine:
            return "High-level graph. Easiest and most compatible, but adds several buffers of latency."
        case .aggregateHAL:
            return "Direct CoreAudio callback over a temporary aggregate device. One shared clock, no drift, lowest latency (LadioCast-style). Creates a hidden virtual device while running."
        case .dualDeviceHAL:
            return "Direct CoreAudio callbacks on separate input/output devices with a ring buffer and drift correction. No virtual device; latency slightly above aggregate."
        }
    }
}

/// Common surface every passthrough engine exposes to the app.
protocol PassthroughEngineProtocol: AnyObject {
    var isRunning: Bool { get }
    var pinnedInputID: AudioDeviceID? { get }

    var desiredSampleRate: Double? { get set }
    var desiredBufferFrames: UInt32? { get set }
    var onInputLostWarning: ((_ message: String) -> Void)? { get set }

    /// Linear gain applied to the passed-through signal (1.0 = unity).
    /// Realtime-safe; read on the audio thread.
    var volume: Float { get set }

    /// Most recent peak signal level (0...1), sampled from the realtime path.
    /// The app polls this to detect silence for the idle timeout.
    var currentPeakLevel: Float { get }

    func start(inputDeviceID: AudioDeviceID) throws
    func stop()
    func refresh()

    @discardableResult func setOutputDevice(_ id: AudioDeviceID) -> Bool
    func setSampleRate(_ rate: Double)
    func setBufferFrames(_ frames: UInt32)
    func applyPreset(_ preset: Preset)
    func handleInputChanged()
}

extension PassthroughEngineProtocol {
    /// Resolve a preset's rate and buffer for the current device.
    /// Stereo (nil buffer) picks a safe low-latency default; a too-small explicit
    /// buffer is clamped up to the device minimum.
    func resolvePreset(_ preset: Preset) -> (rate: Double, frames: UInt32) {
        let target = pinnedInputID ?? AudioDevices.defaultOutput()
        let range = AudioDevices.bufferFrameSizeRange(target)

        var frames: UInt32
        if let explicit = preset.bufferFrames {
            frames = explicit
        } else {
            // "Best" for stereo: 256 is a good latency/stability balance.
            frames = 256
        }
        if let range = range { frames = min(max(frames, range.lowerBound), range.upperBound) }
        return (preset.sampleRate, frames)
    }
}
