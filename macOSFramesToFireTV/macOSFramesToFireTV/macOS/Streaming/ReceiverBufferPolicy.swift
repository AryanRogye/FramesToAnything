/// Receiver buffers are relative to that receiver's latency target. Current
/// cinema receivers target 750 ms; older Fire TV builds target 180 ms.
/// Intentional pre-roll must not trigger a capture restart/quality reduction.
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
        // Audio-clocked video deliberately waits behind audio's pre-roll. That
        // encoded video queue is NOT decoder congestion. Counting its entire
        // duration caused bitrate reductions every two seconds, eventually a
        // resolution change, ScreenCaptureKit restart, and an audible gap.
        // Only video waiting beyond the queued audio is decoder pressure; allow
        // a small margin for HDMI latency and non-atomic receiver reports.
        let excessBacklog = max(0, backlog - max(0, audio))
        if effectiveBuffer < target / 4 && (newUnderruns || newRecoveries) {
            return .starved
        }
        if effectiveBuffer < target / 2 || excessBacklog > max(250, target / 2) {
            return .low
        }
        if effectiveBuffer >= target * 4 / 5 && excessBacklog < max(100, target / 4) &&
            !newUnderruns && !newRecoveries {
            return .healthy
        }
        return .neutral
    }
}
