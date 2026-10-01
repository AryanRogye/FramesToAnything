import Foundation

nonisolated struct LiveCaptionCue: Sendable, Encodable {
    let id: String
    let revision: UInt64
    let startMs: UInt64
    let endMs: UInt64
    let text: String
    let committedText: String
    let partialText: String
    let final: Bool
}

/// One evolving subtitle: committed prefix plus Whisper's replaceable hypothesis.
/// Never queues historical revisions or keys identity to drifting segment timestamps.
nonisolated struct CaptionRevisionState {
    private var id = UUID().uuidString
    private var revision: UInt64 = 0
    private var startMs: UInt64?
    private var committed = ""
    private var finished = false

    mutating func reset() { self = Self() }

    mutating func update(committedText: String, partialText: String,
                         start: Double, end: Double) -> LiveCaptionCue? {
        if finished { reset() }
        if startMs == nil { startMs = UInt64(max(0, start * 1_000)) }
        if !committedText.isEmpty {
            committed = String((committed + " " + committedText).trimmingCharacters(in: .whitespaces).suffix(300))
        }
        let text = String((committed + " " + partialText).trimmingCharacters(in: .whitespaces).suffix(300))
        guard !text.isEmpty else { return nil }
        revision += 1
        finished = partialText.isEmpty
        return LiveCaptionCue(id: id, revision: revision, startMs: max(startMs!, UInt64(max(0, (end - 6) * 1_000))),
                              endMs: UInt64(max(0, end * 1_000)), text: text,
                              committedText: committed, partialText: String(partialText.suffix(300)), final: finished)
    }
}
