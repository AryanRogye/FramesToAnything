import Foundation
import CryptoKit

/// Wire format: HMAC-SHA256(key, UTF8 domain || server challenge (32)
/// || client challenge (32) || sequence (8-byte BE) || exact JSON payload).
/// Challenges bind records to this handshake even if a pairing key is reused.
nonisolated enum ReceiverControlAuthentication {
    static let feature = "authenticated-controls-v1"

    static func proof(key: SymmetricKey, server: Data, client: Data,
                      sequence: UInt64, payload: Data) -> Data {
        var message = Data("receiver-control-v1".utf8)
        message.append(server)
        message.append(client)
        var number = sequence.bigEndian
        withUnsafeBytes(of: &number) { message.append(contentsOf: $0) }
        message.append(payload)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    static func envelope(key: SymmetricKey, server: Data, client: Data,
                         sequence: UInt64, payload: Data) -> [String: Any] {
        ["type": "authenticated_control", "sequence": String(sequence),
         "payload": payload.base64EncodedString(),
         "proof": proof(key: key, server: server, client: client,
                        sequence: sequence, payload: payload).base64EncodedString()]
    }

    static func verify(_ envelope: [String: Any], key: SymmetricKey,
                       server: Data, client: Data, lastSequence: inout UInt64) -> [String: Any]? {
        guard envelope["type"] as? String == "authenticated_control",
              let text = envelope["sequence"] as? String,
              let sequence = UInt64(text), String(sequence) == text, sequence > lastSequence,
              let encoded = envelope["payload"] as? String, let payload = Data(base64Encoded: encoded),
              let tag = envelope["proof"] as? String, let supplied = Data(base64Encoded: tag),
              supplied.count == 32 else { return nil }
        let expected = proof(key: key, server: server, client: client,
                             sequence: sequence, payload: payload)
        // Constant-time comparison of fixed-length tags.
        let difference = zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard difference == 0,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = object["type"] as? String,
              ["receiver_report", "request_keyframe", "remote_media_command"].contains(type)
        else { return nil }
        lastSequence = sequence
        return object
    }
}

