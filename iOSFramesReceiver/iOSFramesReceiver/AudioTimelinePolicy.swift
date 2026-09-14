import Foundation

nonisolated struct AudioClockProgress {
    private var lastPosition: Double?
    private var lastProgressTime: Double = 0

    mutating func isStalled(position: Double, now: Double) -> Bool {
        if lastPosition == nil || position > lastPosition! {
            lastPosition = position
            lastProgressTime = now
        }
        return now - lastProgressTime > 0.5
    }
}

nonisolated enum AudioTimelinePolicy {
    static let maximumQueuedMilliseconds: Int64 = 3_000
    static let discontinuityMilliseconds: Int64 = 100

    enum ClockDecision: Equatable {
        case keep
        case anchor(Double)
        case rebuffer
    }

    static func clockDecision(originSeconds: Double, renderedSeconds: Double,
                              renderAge: Double, scheduledSeconds: Double,
                              outputLatency: Double, videoSeconds: Double) -> ClockDecision {
        guard renderAge <= 0.25, renderedSeconds + renderAge < scheduledSeconds else {
            return .rebuffer
        }
        let audible = originSeconds + renderedSeconds + renderAge - outputLatency
        let drift = abs(audible - videoSeconds)
        if drift > 0.25 { return .rebuffer }
        return drift > 0.02 ? .anchor(audible) : .keep
    }

    static func isDiscontinuous(origin: Int64, scheduledFrames: Int64,
                                sampleRate: Int, incomingTimestamp: Int64) -> Bool {
        guard sampleRate > 0 else { return true }
        let expected = Double(origin) + Double(scheduledFrames) * 1_000 / Double(sampleRate)
        return abs(Double(incomingTimestamp) - expected) > Double(discontinuityMilliseconds)
    }

    static func exceedsBound(queuedFrames: Int64, incomingFrames: Int64, sampleRate: Int) -> Bool {
        guard sampleRate > 0 else { return true }
        return Double(max(0, queuedFrames)) + Double(incomingFrames) >
            Double(sampleRate) * Double(maximumQueuedMilliseconds) / 1_000
    }
}
