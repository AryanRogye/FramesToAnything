import XCTest
import CryptoKit
@testable import PlaybackPolicy

final class ReceiverControlAuthenticationTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 2, count: 32))
    private let server = Data(repeating: 0, count: 32)
    private let client = Data(repeating: 1, count: 32)
    private let payload = Data(#"{"type":"request_keyframe"}"#.utf8)

    func testCrossPlatformVector() {
        let proof = ReceiverControlAuthentication.proof(
            key: key, server: server, client: client, sequence: 1, payload: payload)
        XCTAssertEqual(proof.map { String(format: "%02x", $0) }.joined(),
                       "6869ddeed7d23e5044885a5694477a851b8ab834879fbd2d40715b0f0cfc3a03")
    }

    func testValidControlReplayTamperingAndSessionBinding() {
        var last: UInt64 = 0
        let envelope = ReceiverControlAuthentication.envelope(
            key: key, server: server, client: client, sequence: 1, payload: payload)
        XCTAssertNotNil(ReceiverControlAuthentication.verify(
            envelope, key: key, server: server, client: client, lastSequence: &last))
        XCTAssertEqual(last, 1)
        XCTAssertNil(ReceiverControlAuthentication.verify(
            envelope, key: key, server: server, client: client, lastSequence: &last))
        for field in ["sequence", "payload", "proof"] {
            var corrupted = envelope
            corrupted[field] = field == "sequence" ? "2" : Data("forged".utf8).base64EncodedString()
            XCTAssertNil(ReceiverControlAuthentication.verify(
                corrupted, key: key, server: server, client: client, lastSequence: &last))
            XCTAssertEqual(last, 1) // failed authentication cannot consume a sequence
        }
        last = 0
        XCTAssertNil(ReceiverControlAuthentication.verify(
            envelope, key: key, server: server, client: Data(repeating: 3, count: 32),
            lastSequence: &last))
        XCTAssertNil(ReceiverControlAuthentication.verify(
            ["type": "request_keyframe"], key: key, server: server, client: client, lastSequence: &last))
    }

    func testAllControlTypesAndReorderedRecords() throws {
        var last: UInt64 = 0
        for (index, type) in ["receiver_report", "request_keyframe", "remote_media_command"].enumerated() {
            let data = try JSONSerialization.data(withJSONObject: ["type": type])
            let envelope = ReceiverControlAuthentication.envelope(
                key: key, server: server, client: client, sequence: UInt64(index + 2), payload: data)
            XCTAssertEqual(ReceiverControlAuthentication.verify(
                envelope, key: key, server: server, client: client, lastSequence: &last)?["type"] as? String, type)
        }
        let old = ReceiverControlAuthentication.envelope(
            key: key, server: server, client: client, sequence: 1, payload: payload)
        XCTAssertNil(ReceiverControlAuthentication.verify(
            old, key: key, server: server, client: client, lastSequence: &last))
        let handshake = ReceiverControlAuthentication.envelope(
            key: key, server: server, client: client, sequence: 5, payload: Data(#"{"type":"hello"}"#.utf8))
        XCTAssertNil(ReceiverControlAuthentication.verify(
            handshake, key: key, server: server, client: client, lastSequence: &last))
    }
}

