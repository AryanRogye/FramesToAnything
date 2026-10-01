import Foundation

/// Bounded, 16 kHz mono history. Used only on the caption conversion queue.
/// PTS stays in the capture clock, so a future receiver cue can use media time.
nonisolated struct CaptionAudioWindow: Sendable {
    static let sampleRate = 16_000
    static let capacity = sampleRate * 6
    private(set) var samples: [Float] = []
    private(set) var start: Double = 0
    private(set) var generation = 0
    var end: Double { start + Double(samples.count) / Double(Self.sampleRate) }

    mutating func append(_ incoming: [Float], at timestamp: Double) {
        guard timestamp.isFinite, !incoming.isEmpty else { return }
        if samples.isEmpty || abs(timestamp - end) > 0.002 {
            samples.removeAll(keepingCapacity: true)
            start = timestamp
            generation += 1
        }
        samples.append(contentsOf: incoming)
        if samples.count > Self.capacity {
            let removed = samples.count - Self.capacity
            samples.removeFirst(removed)
            start += Double(removed) / Double(Self.sampleRate)
        }
    }
}
