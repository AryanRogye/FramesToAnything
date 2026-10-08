#if os(macOS)
import OSLog
import Foundation
import SnapCore

/// Receiver buffer reports and the existing bitrate/quality adjustment policy.
/// This extension uses the same transport state and queues; it creates no new pipeline.
extension MacFireTVTransport {
    func configureVideo(maximumQuality: MacStreamQuality) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            qualityLadder = CinemaQualityLevel.ladder(maximum: maximumQuality)
            qualityLevelIndex = 0
            lowBufferReports = 0
            healthySince = nil
            applyCurrentQuality(force: true)
        }
    }

    func handleReceiverReport(_ object: [String: Any]) {
        guard receiverFeatures.contains(Self.receiverReportsFeature) else { return }
        let videoBuffer = object["videoBufferMs"] as? Int ?? 0
        let audioBuffer = object["audioBufferMs"] as? Int ?? 0
        let decoderBacklog = object["decoderBacklogMs"] as? Int ?? 0
        let underruns = object["underruns"] as? Int ?? lastUnderruns
        let recoveries = object["recoveries"] as? Int ?? lastRecoveries
        // Older receivers omit the target and used the original 750 ms buffer.
        // Respect the negotiated receiver target (including older 180 ms Fire
        // TV builds) instead of mistaking intentional pre-roll for starvation.
        let health = ReceiverBufferPolicy.classify(
            video: videoBuffer, audio: audioBuffer, backlog: decoderBacklog,
            target: object["targetBufferMs"] as? Int ?? 750,
            newUnderruns: underruns > lastUnderruns,
            newRecoveries: recoveries > lastRecoveries
        )
        let now = ContinuousClock.now

        if health == .starved {
            stepQualityDown(now: now)
            lowBufferReports = 0
            healthySince = nil
        } else if health == .low {
            lowBufferReports += 1
            healthySince = nil
            if lowBufferReports >= 4 {
                stepQualityDown(now: now)
                lowBufferReports = 0
            }
        } else {
            lowBufferReports = 0
            let remainedHealthy = health == .healthy
            if remainedHealthy {
                healthySince = healthySince ?? now
                if let healthySince,
                   healthySince.duration(to: now) >= .seconds(20) {
                    stepQualityUp(now: now)
                    self.healthySince = nil
                }
            } else {
                healthySince = nil
            }
        }
        lastUnderruns = underruns
        lastRecoveries = recoveries
    }

    func stepQualityDown(now: ContinuousClock.Instant) {
        guard lastQualityChange.duration(to: now) >= .seconds(2),
              qualityLevelIndex + 1 < qualityLadder.count else { return }
        qualityLevelIndex += 1
        lastQualityChange = now
        applyCurrentQuality()
    }

    func stepQualityUp(now: ContinuousClock.Instant) {
        guard lastQualityChange.duration(to: now) >= .seconds(20),
              qualityLevelIndex > 0 else { return }
        qualityLevelIndex -= 1
        lastQualityChange = now
        applyCurrentQuality()
    }

    func applyCurrentQuality(force: Bool = false) {
        guard qualityLadder.indices.contains(qualityLevelIndex) else { return }
        let level = qualityLadder[qualityLevelIndex]
        macTransportLogger.info("Adaptive quality index=\(self.qualityLevelIndex) bitrate=\(level.averageBitRate)")
        mediaEncoder.updateConfiguration(
            .init(
                framesPerSecond: 60,
                averageBitRate: level.averageBitRate,
                keyFrameInterval: 30
            )
        )
        let callback = onAdaptiveQualityChanged
        Task { @MainActor in callback?(level.quality, level.averageBitRate) }
        if force { lastQualityChange = .now }
    }

}
#endif
