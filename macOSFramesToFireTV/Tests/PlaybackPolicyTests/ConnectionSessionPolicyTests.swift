import XCTest
@testable import PlaybackPolicy

final class ConnectionSessionPolicyTests: XCTestCase {
    func testhandshakeCannotSkipOrRepeatSteps() {
        var session = ConnectionSessionPolicy()
        let token = session.begin()!
        XCTAssertTrue(session.begin() == nil)
        XCTAssertTrue(!session.authenticated(generation: token))
        XCTAssertTrue(session.receivedHello(generation: token))
        XCTAssertTrue(!session.receivedHello(generation: token))
        XCTAssertTrue(session.authenticated(generation: token))
        XCTAssertTrue(!session.authenticated(generation: token))
    }

    func testfiftySessionsRejectPreviousCallbacks() {
        var session = ConnectionSessionPolicy()
        var previous: UInt64 = 0
        for _ in 0..<50 {
            let token = session.begin()!
            XCTAssertTrue(!session.receivedHello(generation: previous))
            XCTAssertTrue(session.receivedHello(generation: token))
            XCTAssertTrue(session.authenticated(generation: token))
            session.end()
            XCTAssertTrue(session.phase == .idle)
            XCTAssertTrue(!session.authenticated(generation: token))
            previous = token
        }
    }

    func testunauthenticatedFailureReleasesAdmission() {
        var session = ConnectionSessionPolicy()
        let stalled = session.begin()!
        session.end()
        let replacement = session.begin()!
        XCTAssertTrue(!session.receivedHello(generation: stalled))
        XCTAssertTrue(session.receivedHello(generation: replacement))
    }
    func testCodeAuthorizationIsScopedAndExpiresAtDeadline() {
        let now = ContinuousClock.now
        let expiry = now.advanced(by: .seconds(120))
        XCTAssertTrue(ConnectionSessionPolicy.permitsCode(code: "123456", target: "tv-a",
                      receiver: "tv-a", expiresAt: expiry, now: now))
        XCTAssertFalse(ConnectionSessionPolicy.permitsCode(code: "123456", target: "tv-a",
                       receiver: "tv-b", expiresAt: expiry, now: now))
        XCTAssertFalse(ConnectionSessionPolicy.permitsCode(code: "123456", target: nil,
                       receiver: "tv-a", expiresAt: expiry, now: now))
        XCTAssertFalse(ConnectionSessionPolicy.permitsCode(code: "123456", target: "tv-a",
                       receiver: "tv-a", expiresAt: expiry, now: expiry))
        XCTAssertFalse(ConnectionSessionPolicy.permitsCode(code: "", target: "tv-a",
                       receiver: "tv-a", expiresAt: expiry, now: now))
        XCTAssertFalse(ConnectionSessionPolicy.permitsCode(code: "12345x", target: "tv-a",
                       receiver: "tv-a", expiresAt: expiry, now: now))
    }

}
