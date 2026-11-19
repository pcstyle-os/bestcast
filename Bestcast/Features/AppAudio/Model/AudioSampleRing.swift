import Synchronization

/// One writer (the tap's I/O thread) and one reader (the output's render thread), never a lock.
/// See docs/features/app-audio.md.
nonisolated final class AudioSampleRing: @unchecked Sendable {
    let channels: Int
    private let capacity: Int
    /// A reader further behind than this skips ahead, so a stall never turns into lasting delay.
    private let maximumLag: Int
    private let samples: UnsafeMutablePointer<Float>
    /// Frame counts, never wrapped; only the writer stores `written`, only the reader `read`.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    /// The reader's position between two frames; only the reader touches it.
    private var phase = 0.0

    init(channels: Int, capacity: Int, maximumLag: Int) {
        precondition(channels > 0 && maximumLag < capacity)
        self.channels = channels
        self.capacity = capacity
        self.maximumLag = maximumLag
        samples = .allocate(capacity: capacity * channels)
        samples.initialize(repeating: 0, count: capacity * channels)
    }

    deinit { samples.deallocate() }

    /// Interleaved frames; a source with fewer channels repeats its last one.
    func write(_ source: UnsafePointer<Float>, frames: Int, sourceChannels: Int) {
        let start = written.load(ordering: .relaxed)
        // Never overtake the reader: a full ring drops the newest frames instead.
        let count = min(frames, capacity - (start - read.load(ordering: .acquiring)))
        for frame in 0..<max(count, 0) {
            let slot = (start + frame) % capacity * channels
            for channel in 0..<channels {
                samples[slot + channel] = source[frame * sourceChannels + min(channel, sourceChannels - 1)]
            }
        }
        written.store(start + max(count, 0), ordering: .releasing)
    }

    /// `step` is source frames per output frame, so an output at another rate keeps its pitch.
    func read(
        into output: UnsafeMutablePointer<Float>, frames: Int, outputChannels: Int, gain: Float, step: Double = 1
    ) {
        let end = written.load(ordering: .acquiring)
        var position = Double(read.load(ordering: .relaxed)) + phase
        if Double(end) - position > Double(maximumLag) { position = Double(end - maximumLag / 2) }
        for frame in 0..<frames {
            let index = Int(position)
            // Slots past `end` are still the writer's, so an underrun never reads them.
            guard index + 1 < end else {
                output.advanced(by: frame * outputChannels).update(repeating: 0, count: outputChannels)
                continue
            }
            let fraction = Float(position - Double(index))
            let here = index % capacity * channels
            let next = (index + 1) % capacity * channels
            for channel in 0..<outputChannels {
                let source = min(channel, channels - 1)
                let sample = samples[here + source] + (samples[next + source] - samples[here + source]) * fraction
                output[frame * outputChannels + channel] = sample * gain
            }
            position += step
        }
        phase = position - position.rounded(.down)
        read.store(Int(position), ordering: .releasing)
    }
}
