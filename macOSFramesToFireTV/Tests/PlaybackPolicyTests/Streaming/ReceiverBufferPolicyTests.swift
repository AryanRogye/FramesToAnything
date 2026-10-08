import XCTest
@testable import PlaybackPolicy

final class ReceiverBufferPolicyTests: XCTestCase {
    func testHealthyFireTVDoesNotTriggerCaptureRestart() {
        for buffer in [150, 180, 200] {
            XCTAssertEqual(classify(video: buffer, audio: buffer), .healthy)
        }
    }

    func testStillDesktopDoesNotLookLikeNetworkStarvation() {
        XCTAssertEqual(classify(video: 0, audio: 180), .healthy)
    }

    func testBriefDipIsNotAnEmergency() {
        XCTAssertEqual(classify(video: 30, audio: 30), .low)
    }

    func testActualUnderrunAtLowBufferIsAnEmergency() {
        XCTAssertEqual(classify(video: 30, audio: 30, underrun: true), .starved)
    }

    func testOlderReceiverTargetRemainsSupported() {
        XCTAssertEqual(classify(video: 700, audio: 700, target: 750), .healthy)
        XCTAssertEqual(classify(video: 180, audio: 180, target: 750), .low)
    }

    func testCinemaPrerollIsNotDecoderCongestion() {
        // Held video plus HDMI's output latency is normal, not a reason to
        // restart screen/audio capture at a lower resolution every two seconds.
        for backlog in [650, 750, 900] {
            XCTAssertEqual(ReceiverBufferPolicy.classify(
                video: 950, audio: 750, backlog: backlog, target: 750,
                newUnderruns: false, newRecoveries: false
            ), .healthy)
        }
    }

    func testDecoderFallingBehindAudioStillReducesQuality() {
        XCTAssertEqual(ReceiverBufferPolicy.classify(
            video: 1_800, audio: 750, backlog: 1_500, target: 750,
            newUnderruns: false, newRecoveries: false
        ), .low)
    }

    func testEmptyAudioIsNotHiddenByLargeVideoPreroll() {
        XCTAssertEqual(ReceiverBufferPolicy.classify(
            video: 1_800, audio: 0, backlog: 1_500, target: 750,
            newUnderruns: true, newRecoveries: false
        ), .starved)
    }

    private func classify(
        video: Int, audio: Int, target: Int = 180, underrun: Bool = false
    ) -> ReceiverBufferPolicy.Health {
        ReceiverBufferPolicy.classify(
            video: video, audio: audio, backlog: 0, target: target,
            newUnderruns: underrun, newRecoveries: false
        )
    }
}
