/// Receiver buffers are relative to that receiver's latency target. Fire TV
/// targets 180 ms; iOS targets 750 ms. Applying the iOS thresholds to Fire TV
/// makes healthy playback repeatedly restart capture as quality is reduced.
nonisolated enum ReceiverBufferPolicy {
    enum Health { case starved, low, healthy, neutral }

    static func classify(
        video: Int, audio: Int, backlog: Int, target: Int,
        newUnderruns: Bool, newRecoveries: Bool
    ) -> Health {
        let target = max(100, min(target, 2_000))
        // A still desktop can legitimately have no queued video. Actual audio
        // starvation, or new recovery events, is stronger evidence of trouble.
        let effectiveBuffer = video > 0 ? min(video, audio) : audio
        if effectiveBuffer < target / 4 && (newUnderruns || newRecoveries) {
            return .starved
        }
        if effectiveBuffer < target / 2 || backlog > max(250, target) {
            return .low
        }
        if effectiveBuffer >= target * 4 / 5 && backlog < max(100, target / 2) &&
            !newUnderruns && !newRecoveries {
            return .healthy
        }
        return .neutral
    }
}
