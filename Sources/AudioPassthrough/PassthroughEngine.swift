import Foundation
import AVFoundation
import CoreAudio

/// Routes the app's chosen input device straight to the current default output.
///
/// Behavior:
/// - Output follows the system default automatically (AVAudioEngine's output node
///   tracks the current default output device, so no extra work is needed there).
/// - Input is pinned to a device the user selected. If the system default input
///   changes out from under us, we try to switch it back; if that fails we warn.
final class PassthroughEngine: PassthroughEngineProtocol {

    private let engine = AVAudioEngine()
    private var running = false

    private var peak: Float = 0
    private let peakLock = NSLock()
    var currentPeakLevel: Float { peakLock.lock(); defer { peakLock.unlock() }; return peak }

    private var _volume: Float = 1.0
    var volume: Float {
        get { _volume }
        set {
            _volume = max(0, newValue)
            engine.mainMixerNode.outputVolume = _volume
        }
    }

    /// The input device the user asked to listen to (their 3.5mm line-in).
    private(set) var pinnedInputID: AudioDeviceID?

    /// Optional manual overrides. When nil, the device's current values are kept.
    var desiredSampleRate: Double?
    var desiredBufferFrames: UInt32?

    /// Called when the input drifts and we cannot restore it.
    var onInputLostWarning: ((_ message: String) -> Void)?

    // MARK: - Control

    func start(inputDeviceID: AudioDeviceID) throws {
        stop()
        pinnedInputID = inputDeviceID

        // Force the OS default input to our chosen device so AVAudioEngine's
        // inputNode taps it. (AVAudioEngine on macOS uses the default input.)
        AudioDevices.setDefaultInput(inputDeviceID)

        // Apply manual hardware settings to both endpoints before wiring up.
        applyHardwareSettings(inputID: inputDeviceID,
                              outputID: AudioDevices.defaultOutput())

        let input = engine.inputNode
        let output = engine.outputNode
        let format = input.inputFormat(forBus: 0)

        // Direct connection: input -> mainMixer -> output.
        engine.connect(input, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: output, format: nil)
        engine.mainMixerNode.outputVolume = _volume

        installLevelTap(on: input, format: format)

        engine.prepare()
        try engine.start()
        running = true
    }

    private func installLevelTap(on node: AVAudioNode, format: AVAudioFormat) {
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, let ch = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var p: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                let data = ch[c]
                for i in 0..<frames { let m = abs(data[i]); if m > p { p = m } }
            }
            // Peak-hold with time-based decay so brief dips aren't seen as silence.
            let rate = Float(buffer.format.sampleRate > 0 ? buffer.format.sampleRate : 48_000)
            let dt = Float(max(1, frames)) / rate
            let decay = exp(-dt / 0.6)
            self.peakLock.lock()
            self.peak = max(p, self.peak * decay)
            self.peakLock.unlock()
        }
    }

    func stop() {
        if running {
            engine.stop()
            engine.reset()
            running = false
        }
        pinnedInputID = nil
    }

    var isRunning: Bool { running }

    // MARK: - Manual settings

    /// Push the desired sample rate / buffer size onto the input and output HW.
    /// Matching sample rates on both ends avoids implicit SRC in the engine.
    private func applyHardwareSettings(inputID: AudioDeviceID, outputID: AudioDeviceID) {
        if let rate = desiredSampleRate {
            AudioDevices.setNominalSampleRate(inputID, rate)
            AudioDevices.setNominalSampleRate(outputID, rate)
        }
        if let frames = desiredBufferFrames {
            AudioDevices.setBufferFrameSize(inputID, frames)
            AudioDevices.setBufferFrameSize(outputID, frames)
        }
    }

    /// Manually switch the output device. Output otherwise follows the system
    /// default; setting it here changes the system default so the engine follows.
    @discardableResult
    func setOutputDevice(_ id: AudioDeviceID) -> Bool {
        // AVAudioEngine's output node already follows the system default; the
        // output-change listener triggers a refresh to re-establish the graph.
        return AudioDevices.setDefaultOutput(id)
    }

    func setSampleRate(_ rate: Double) {
        desiredSampleRate = rate
        if running { refresh() }
    }

    func setBufferFrames(_ frames: UInt32) {
        desiredBufferFrames = frames
        if running { refresh() }
    }

    /// One-click optimization for a listening target.
    func applyPreset(_ preset: Preset) {
        let resolved = resolvePreset(preset)
        desiredSampleRate = resolved.rate
        desiredBufferFrames = resolved.frames
        if running { refresh() }
    }

    /// Tear down and rebuild the routing pipeline with current settings.
    /// Use after changing rate/buffer/output, or to recover from glitches.
    func refresh() {
        guard let input = pinnedInputID else { return }
        do {
            engine.stop()
            engine.reset()
            applyHardwareSettings(inputID: input, outputID: AudioDevices.defaultOutput())
            let inNode = engine.inputNode
            let format = inNode.inputFormat(forBus: 0)
            engine.connect(inNode, to: engine.mainMixerNode, format: format)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
            engine.mainMixerNode.outputVolume = _volume
            installLevelTap(on: inNode, format: format)
            engine.prepare()
            try engine.start()
            running = true
        } catch {
            running = false
            onInputLostWarning?("Failed to refresh audio pipeline: \(error.localizedDescription)")
        }
    }

    // MARK: - Input drift handling

    /// Call when the system default input changed. Attempts to restore the pinned
    /// input; warns via `onInputLostWarning` if restoration fails.
    func handleInputChanged() {
        guard running, let pinned = pinnedInputID else { return }
        let current = AudioDevices.defaultInput()
        if current == pinned { return } // nothing to do

        // Is the pinned device still present at all?
        let stillPresent = AudioDevices.inputs().contains { $0.id == pinned }
        guard stillPresent else {
            let name = AudioDevices.device(for: current)?.name ?? "another device"
            onInputLostWarning?("Your line-in input was disconnected. Output is now coming from “\(name)”.")
            return
        }

        // Try to switch back.
        if AudioDevices.setDefaultInput(pinned) {
            // Rebuild the input connection so the engine re-taps the restored device.
            restartInputTap()
        } else {
            let name = AudioDevices.device(for: pinned)?.name ?? "your input"
            onInputLostWarning?("Couldn’t switch the input back to “\(name)”. It may be in use by another app.")
        }
    }

    private func restartInputTap() {
        guard let pinned = pinnedInputID else { return }
        do {
            engine.stop()
            engine.reset()
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            engine.connect(input, to: engine.mainMixerNode, format: format)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
            try engine.start()
            running = true
        } catch {
            let name = AudioDevices.device(for: pinned)?.name ?? "your input"
            onInputLostWarning?("Restored “\(name)” but the audio engine failed to restart: \(error.localizedDescription)")
        }
    }
}
