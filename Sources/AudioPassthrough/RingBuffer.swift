import Foundation
import Atomics

/// Single-producer / single-consumer lockless ring buffer for interleaved
/// float samples. The input IOProc writes; the output IOProc reads. No locks,
/// no allocation on the audio thread.
final class RingBuffer {

    private var storage: UnsafeMutablePointer<Float>
    private let capacity: Int              // in samples (frames * channels), power of 2
    private let mask: Int
    private let writeIndex = ManagedAtomic<Int>(0)
    private let readIndex = ManagedAtomic<Int>(0)

    init(capacityFrames: Int, channels: Int) {
        // Round up to a power of two for cheap masking.
        let needed = capacityFrames * channels
        var cap = 1
        while cap < needed { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        storage.initialize(repeating: 0, count: cap)
    }

    deinit {
        storage.deallocate()
    }

    var availableToRead: Int {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        return w - r
    }

    /// Write `count` samples from `src`. Drops oldest if it would overrun
    /// (keeps latency bounded instead of blocking).
    func write(_ src: UnsafePointer<Float>, count: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        for i in 0..<count {
            storage[(w + i) & mask] = src[i]
        }
        writeIndex.store(w + count, ordering: .releasing)
    }

    /// Read `count` samples into `dst`. Fills with silence if underrun.
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        let avail = w - r
        if avail >= count {
            for i in 0..<count {
                dst[i] = storage[(r + i) & mask]
            }
            readIndex.store(r + count, ordering: .releasing)
        } else {
            // Underrun: output what we have, pad the rest with silence.
            for i in 0..<avail { dst[i] = storage[(r + i) & mask] }
            for i in avail..<count { dst[i] = 0 }
            readIndex.store(r + max(avail, 0), ordering: .releasing)
        }
    }

    func reset() {
        writeIndex.store(0, ordering: .releasing)
        readIndex.store(0, ordering: .releasing)
        storage.update(repeating: 0, count: capacity)
    }
}
