import Foundation
import CoreAudio

/// Creates and tears down a private aggregate device that wraps an input and an
/// output sub-device under a single clock. This is what gives the aggregate-HAL
/// engine its low, drift-free latency.
enum AggregateDevice {

    /// Create a private (non-persistent) aggregate device.
    /// - Returns: the new aggregate's AudioDeviceID, or nil on failure.
    static func create(inputUID: String, outputUID: String,
                       masterUID: String, sampleRate: Double) -> AudioDeviceID? {

        let aggUID = "com.llinput.app.aggregate"

        // Sub-device list: input first, output second. Order affects channel layout.
        // The output (follower) gets drift compensation so it resamples to the
        // master (input) clock instead of glitching.
        let subDevices: [[String: Any]] = [
            [kAudioSubDeviceUIDKey as String: inputUID],
            [kAudioSubDeviceUIDKey as String: outputUID,
             kAudioSubDeviceDriftCompensationKey as String: 1],
        ]

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "LL Input Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices,
            kAudioAggregateDeviceMasterSubDeviceKey as String: masterUID,
            // Private: not shown to other apps, removed when we release it.
            kAudioAggregateDeviceIsPrivateKey as String: 1,
        ]

        var aggID = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard status == noErr, aggID != 0 else { return nil }

        if sampleRate > 0 {
            AudioDevices.setNominalSampleRate(aggID, sampleRate)
        }
        return aggID
    }

    static func destroy(_ id: AudioDeviceID) {
        guard id != 0 else { return }
        AudioHardwareDestroyAggregateDevice(id)
    }
}
