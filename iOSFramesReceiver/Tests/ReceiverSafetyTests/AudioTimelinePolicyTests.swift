import XCTest
@testable import ReceiverSafety

final class AudioTimelinePolicyTests: XCTestCase {
    func testFrozenSamplePositionIsDetectedEvenWithFreshHostTimestamps() {
        var progress = AudioClockProgress()
        XCTAssertFalse(progress.isStalled(position: 1, now: 10))
        XCTAssertFalse(progress.isStalled(position: 1, now: 10.2))
        XCTAssertTrue(progress.isStalled(position: 1, now: 10.6))
        progress = AudioClockProgress()
        for tick in 0..<10_000 {
            XCTAssertFalse(progress.isStalled(position: Double(tick) / 10, now: Double(tick) / 10))
        }
    }
    func testAudioClockAnchorsToAudiblePositionNotHostElapsedTime() {
        XCTAssertEqual(AudioTimelinePolicy.clockDecision(
            originSeconds: 10, renderedSeconds: 1, renderAge: 0.01,
            scheduledSeconds: 2, outputLatency: 0.1, videoSeconds: 11),
            .anchor(10 + 1 + 0.01 - 0.1))
        XCTAssertEqual(AudioTimelinePolicy.clockDecision(
            originSeconds: 10, renderedSeconds: 1, renderAge: 0.01,
            scheduledSeconds: 2, outputLatency: 0.1, videoSeconds: 10.91), .keep)
    }

    func testStarvationStaleRenderAndLargeDriftRebufferBothStreams() {
        XCTAssertEqual(AudioTimelinePolicy.clockDecision(
            originSeconds: 10, renderedSeconds: 2, renderAge: 0,
            scheduledSeconds: 2, outputLatency: 0, videoSeconds: 12), .rebuffer)
        XCTAssertEqual(AudioTimelinePolicy.clockDecision(
            originSeconds: 10, renderedSeconds: 1, renderAge: 0.3,
            scheduledSeconds: 2, outputLatency: 0, videoSeconds: 11.3), .rebuffer)
        XCTAssertEqual(AudioTimelinePolicy.clockDecision(
            originSeconds: 10, renderedSeconds: 1, renderAge: 0,
            scheduledSeconds: 2, outputLatency: 0, videoSeconds: 12), .rebuffer)
    }

    func testCinemaPrerollFitsButFailedStartupIsBounded() {
        XCTAssertFalse(AudioTimelinePolicy.exceedsBound(queuedFrames: 0, incomingFrames: 36_000, sampleRate: 48_000))
        XCTAssertFalse(AudioTimelinePolicy.exceedsBound(queuedFrames: 143_000, incomingFrames: 1_000, sampleRate: 48_000))
        XCTAssertTrue(AudioTimelinePolicy.exceedsBound(queuedFrames: 144_000, incomingFrames: 1, sampleRate: 48_000))
        XCTAssertTrue(AudioTimelinePolicy.exceedsBound(queuedFrames: 0, incomingFrames: 144_001, sampleRate: 48_000))
    }

    func testContiguousCaptureDoesNotAccumulatePacketRoundingError() {
        for packet in 0..<100_000 {
            let frames = Int64(packet * 1024)
            let timestamp = 42_000 + Int64(Double(frames) * 1000 / 44_100)
            XCTAssertFalse(AudioTimelinePolicy.isDiscontinuous(
                origin: 42_000, scheduledFrames: frames, sampleRate: 44_100, incomingTimestamp: timestamp))
        }
    }

    func testForwardAndBackwardTimestampGapsRequireRebuffer() {
        for timestamp: Int64 in [2_250, 1_750] {
            XCTAssertTrue(AudioTimelinePolicy.isDiscontinuous(
                origin: 1_000, scheduledFrames: 48_000, sampleRate: 48_000, incomingTimestamp: timestamp))
        }
    }
}
