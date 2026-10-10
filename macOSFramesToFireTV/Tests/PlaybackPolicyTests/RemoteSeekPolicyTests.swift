import XCTest
@testable import PlaybackPolicy

final class RemoteSeekPolicyTests: XCTestCase {
    func testTenSecondSeekAndBoundaries() {
        XCTAssertEqual(RemoteSeekPolicy.target(elapsed: 30, duration: 100, offset: 10), 40)
        XCTAssertEqual(RemoteSeekPolicy.target(elapsed: 30, duration: 100, offset: -10), 20)
        XCTAssertEqual(RemoteSeekPolicy.target(elapsed: 3, duration: 100, offset: -10), 0)
        XCTAssertEqual(RemoteSeekPolicy.target(elapsed: 95, duration: 100, offset: 10), 100)
    }

    func testLiveMissingAndInvalidMetadataNeverSeeks() {
        for duration: Double? in [nil, 0, -1, .infinity, .nan] {
            XCTAssertNil(RemoteSeekPolicy.target(elapsed: 30, duration: duration, offset: 10))
        }
        for elapsed: Double? in [nil, -1, .infinity, .nan] {
            XCTAssertNil(RemoteSeekPolicy.target(elapsed: elapsed, duration: 100, offset: 10))
        }
    }

    func testOnlyAllowlistedCommandsAndOffsets() {
        XCTAssertNil(RemoteMediaCommand(rawValue: "seek_forward_30"))
        XCTAssertNil(RemoteMediaCommand(rawValue: "set_time"))
        XCTAssertNil(RemoteMediaCommand.togglePlayPause.seekOffset)
        XCTAssertEqual(RemoteMediaCommand.seekForward10.seekOffset, 10)
        XCTAssertEqual(RemoteMediaCommand.seekBackward10.seekOffset, -10)
        for offset in [0.0, 15, 1_000, Double.nan, Double.infinity] {
            XCTAssertNil(RemoteSeekPolicy.target(elapsed: 30, duration: 100, offset: offset))
        }
    }
}
