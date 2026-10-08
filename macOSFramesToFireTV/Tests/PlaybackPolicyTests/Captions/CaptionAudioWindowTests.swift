import XCTest
@testable import PlaybackPolicy

final class CaptionAudioWindowTests: XCTestCase {
    func testLongStreamRetainsOnlyNewestSixSecondsOnCaptureClock() {
        var window = CaptionAudioWindow()
        for second in 0..<120 {
            window.append(Array(repeating: Float(second), count: 16_000), at: 400 + Double(second))
            XCTAssertLessThanOrEqual(window.samples.count, CaptionAudioWindow.capacity)
        }
        XCTAssertEqual(window.start, 514, accuracy: 0.0001)
        XCTAssertEqual(window.end, 520, accuracy: 0.0001)
        XCTAssertEqual(window.samples.first, 114)
        XCTAssertEqual(window.samples.last, 119)
        XCTAssertEqual(window.generation, 1)
    }

    func testDroppedAudioAndClockRestartDoNotJoinUnrelatedSpeech() {
        var window = CaptionAudioWindow()
        window.append(Array(repeating: 1, count: 160), at: 20)
        let firstGeneration = window.generation
        window.append(Array(repeating: 2, count: 160), at: 20.02)
        XCTAssertEqual(window.samples.count, 160)
        XCTAssertGreaterThan(window.generation, firstGeneration)
        window.append(Array(repeating: 3, count: 160), at: 1)
        XCTAssertEqual(window.start, 1)
        XCTAssertEqual(window.samples, Array(repeating: 3, count: 160))
    }

    func testSnapshotIsStableWhileCaptureContinues() {
        var window = CaptionAudioWindow()
        window.append(Array(repeating: 1, count: 16_000), at: 10)
        let snapshot = window
        window.append(Array(repeating: 2, count: 16_000), at: 11)
        XCTAssertEqual(snapshot.end, 11)
        XCTAssertEqual(snapshot.samples.count, 16_000)
        XCTAssertEqual(window.end, 12)
    }

    func testInvalidAndEmptyInputDoNotCorruptTimeline() {
        var window = CaptionAudioWindow()
        window.append([1], at: .nan)
        window.append([], at: 50)
        XCTAssertTrue(window.samples.isEmpty)
        XCTAssertEqual(window.generation, 0)
    }
}
