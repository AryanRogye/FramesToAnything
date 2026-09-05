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

    private func classify(
        video: Int, audio: Int, target: Int = 180, underrun: Bool = false
    ) -> ReceiverBufferPolicy.Health {
        ReceiverBufferPolicy.classify(
            video: video, audio: audio, backlog: 0, target: target,
            newUnderruns: underrun, newRecoveries: false
        )
    }
}
