import XCTest
@testable import PlaybackPolicy

final class CaptionRevisionStateTests: XCTestCase {
    func testPartialRefinementKeepsIdentityAndCommittedPrefix() throws {
        var state = CaptionRevisionState()
        let first = try XCTUnwrap(state.update(committedText: "", partialText: "Now", start: 100, end: 101))
        let revised = try XCTUnwrap(state.update(committedText: "", partialText: "Now the last option", start: 100.2, end: 102))
        XCTAssertEqual(first.id, revised.id)
        XCTAssertGreaterThan(revised.revision, first.revision)
        XCTAssertEqual(revised.text, "Now the last option")
        XCTAssertEqual(revised.committedText, "")
        XCTAssertEqual(revised.partialText, "Now the last option")
        let next = try XCTUnwrap(state.update(committedText: "Now the last option", partialText: "is simple", start: 100, end: 103))
        XCTAssertEqual(next.id, first.id)
        XCTAssertEqual(next.text, "Now the last option is simple")
        XCTAssertEqual(next.committedText, "Now the last option")
        XCTAssertEqual(next.partialText, "is simple")
        let final = try XCTUnwrap(state.update(committedText: "is simple.", partialText: "", start: 102, end: 104))
        XCTAssertEqual(final.id, first.id)
        XCTAssertTrue(final.final)
        XCTAssertEqual(final.committedText, "Now the last option is simple.")
        XCTAssertEqual(final.partialText, "")
        let new = try XCTUnwrap(state.update(committedText: "", partialText: "Next", start: 104, end: 105))
        XCTAssertNotEqual(new.id, final.id)
        XCTAssertEqual(new.text, "Next")
    }
}
