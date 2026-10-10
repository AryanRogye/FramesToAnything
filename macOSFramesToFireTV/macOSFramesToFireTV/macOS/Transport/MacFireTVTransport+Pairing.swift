#if os(macOS)
import OSLog
import CommonCrypto
import CryptoKit
import Foundation
import Network
import Security
import SnapCore

/// Incoming JSON framing, pairing authentication, remembered trust, and receiver commands.
/// This extension uses the same transport state and queues; it creates no new pipeline.
extension MacFireTVTransport {
    nonisolated func receiveNextChunk(from connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, connection === self.connection else { return }
            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                processPackets()
            }
            // Processing an authentication failure tears down this connection.
            // Do not replace that useful error with the subsequent normal EOF.
            guard connection === self.connection else { return }
            if let error {
                fail("Connection ended: \(error.localizedDescription)")
            } else if isComplete {
                fail("The Fire TV ended the connection.")
            } else {
                receiveNextChunk(from: connection)
            }
        }
    }

    nonisolated func processPackets() {
        while receiveBuffer.count >= 4 {
            let length = receiveBuffer.prefix(4).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0, length <= Self.maximumJSONPacketBytes else {
                fail("The Fire TV sent an invalid authentication message.")
                return
            }
            let fullLength = 4 + Int(length)
            guard receiveBuffer.count >= fullLength else { return }
            let packet = receiveBuffer.subdata(in: 4..<fullLength)
            receiveBuffer.removeSubrange(0..<fullLength)
            guard packet.first == Self.jsonPacket else { continue }
            handleJSON(packet.dropFirst())
        }
    }

    nonisolated func handleJSON(_ bytes: Data.SubSequence) {
        guard var object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              var type = object["type"] as? String else {
            fail("The Fire TV sent an unreadable authentication message.")
            return
        }
        if let key = currentStreamingKey() {
            // Session authentication alone does not authenticate a control.
            // Ignore unsigned records (including replayed handshakes).
            guard receiverFeatures.contains(ReceiverControlAuthentication.feature),
                  let serverChallenge, let clientChallenge,
                  let verified = ReceiverControlAuthentication.verify(
                    object, key: key, server: serverChallenge, client: clientChallenge,
                    lastSequence: &lastControlSequence
                  ), let verifiedType = verified["type"] as? String else { return }
            lastAuthenticatedControl = .now
            object = verified
            type = verifiedType
        } else if !["hello", "auth_ok", "auth_failed"].contains(type) {
            return
        }
        switch type {
        case "hello":
            guard session.phase == .awaitingHello else { fail("Unexpected handshake message."); return }
            guard (object["version"] as? Int) == 1,
                  let saltValue = object["salt"] as? String,
                  let challengeValue = object["challenge"] as? String,
                  let salt = Data(base64Encoded: saltValue),
                  let serverChallenge = Data(base64Encoded: challengeValue),
                  salt.count == 16, serverChallenge.count == 32 else {
                fail("The receiver uses an unsupported authentication protocol.")
                return
            }
            let clientChallenge = Self.randomData(count: 32)
            receiverFeatures = Set(object["features"] as? [String] ?? [])
            let helloReceiverID = object["receiverID"] as? String
            if let expectedID = pairingTarget,
               let helloReceiverID,
               expectedID != helloReceiverID {
                rejectUnexpectedReceiver()
                return
            }
            receiverID = helloReceiverID ?? receiverID
            if let receiverID { rememberedSecret = TrustedReceiverStore.load(receiverID) }
            if let receiverID {
                connectedName = "Receiver \(receiverID.prefix(8))"
            }
            let authorizedCode = ConnectionSessionPolicy.permitsCode(
                code: pairingCode, target: pairingTarget, receiver: receiverID,
                expiresAt: pairingExpiresAt, now: .now
            )
            guard rememberedSecret != nil || authorizedCode else {
                rejectForPairing()
                return
            }
            let trustedSecret = rememberedSecret
            let keyData: Data?
            let mode: String
            if let trustedSecret {
                keyData = Self.deriveRememberedSessionKey(
                    secret: trustedSecret,
                    salt: salt,
                    serverChallenge: serverChallenge,
                    clientChallenge: clientChallenge
                )
                mode = "remembered"
                usedRememberedSecret = true
            } else {
                keyData = Self.deriveKey(code: pairingCode, salt: salt)
                mode = "code"
            }
            guard let keyData else {
                fail("Could not create a secure session key.")
                return
            }
            let key = SymmetricKey(data: keyData)
            self.serverChallenge = serverChallenge
            self.clientChallenge = clientChallenge
            handshakeKey = key
            _ = session.receivedHello(generation: session.generation)
            report(.authenticating(usedRememberedSecret))
            let proof = Self.authenticationCode(
                key: key,
                label: "client",
                serverChallenge: serverChallenge,
                clientChallenge: clientChallenge
            )
            sendJSON([
                "type": "auth",
                "name": Host.current().localizedName ?? "Mac",
                "senderID": Self.senderID,
                "mode": mode,
                "challenge": clientChallenge.base64EncodedString(),
                "proof": proof.base64EncodedString(),
                "acceptedFeatures": Array(receiverFeatures.intersection(Self.cinemaFeatures)).sorted(),
            ])

        case "auth_ok":
            guard session.phase == .authenticating else { fail("Unexpected authentication response."); return }
            guard let proofValue = object["proof"] as? String,
                  let suppliedProof = Data(base64Encoded: proofValue),
                  let key = handshakeKey,
                  let serverChallenge,
                  let clientChallenge else {
                fail("The receiver did not complete authentication.")
                return
            }
            let expected = Self.authenticationCode(
                key: key,
                label: "server",
                serverChallenge: serverChallenge,
                clientChallenge: clientChallenge
            )
            guard Self.constantTimeEqual(suppliedProof, expected) else {
                fail("The Fire TV identity check failed.")
                return
            }
            if let acceptedFeatures = object["acceptedFeatures"] as? [String] {
                receiverFeatures.formIntersection(acceptedFeatures)
            }
            if !usedRememberedSecret, let receiverID {
                let secret = Self.deriveTrustSecret(
                    key: key,
                    serverChallenge: serverChallenge,
                    clientChallenge: clientChallenge
                )
                TrustedReceiverStore.save(secret, for: receiverID)
            }
            if let receiverID {
                TrustedReceiverStore.associate(
                    receiverID: receiverID,
                    withServiceName: connectedName
                )
            }
            _ = session.authenticated(generation: session.generation)
            handshakeDeadline?.cancel()
            handshakeDeadline = nil
            pairingCode = ""
            pairingTarget = nil
            pairingExpiresAt = nil
            setUsesAACAudio(receiverFeatures.contains(Self.aacFeature))
            setStreamingKey(key)
            startHeartbeat()
            report(.connected(connectedName))

        case "auth_failed":
            if usedRememberedSecret {
                fail("This receiver no longer remembers your Mac. Enter its current code once to pair again.")
            } else {
                fail("That pairing code was not accepted. The receiver has generated a new code.")
            }
        case "heartbeat":
            break
        case "request_keyframe":
            guard currentStreamingKey() != nil,
                  receiverFeatures.contains("keyframe-request-v1") else { return }
            macTransportLogger.info("Receiver requested a clean H.264 keyframe")
            mediaEncoder.stop()
            mediaEncoder.restart()

        case "receiver_report":
            guard currentStreamingKey() != nil else { return }
            handleReceiverReport(object)

        case "remote_media_command":
            guard currentStreamingKey() != nil,
                  receiverFeatures.contains(Self.remoteMediaControlsFeature),
                  let value = object["command"] as? String,
                  let command = RemoteMediaCommand(rawValue: value) else { return }
            if command.seekOffset != nil {
                guard receiverFeatures.contains(Self.remoteSeekFeature),
                      let requestID = object["requestID"] as? String,
                      UUID(uuidString: requestID) != nil else { return }
                let now = ContinuousClock.now
                guard lastRemoteMediaCommand.duration(to: now) >= .milliseconds(200) else { return }
                lastRemoteMediaCommand = now
                let generation = currentMediaGeneration()
                Task { @MainActor [weak self] in
                    guard let self, currentMediaGeneration() == generation else { return }
                    MacRemoteSeekController.shared.seek(command: command, isCurrent: { [weak self] in
                        self?.currentMediaGeneration() == generation
                    }, completion: { [weak self] status in
                        self?.sendRemoteSeekResult(requestID: requestID, command: command,
                                                   status: status, generation: generation)
                    })
                }
            } else {
                let now = ContinuousClock.now
                guard lastRemoteMediaCommand.duration(to: now) >= .milliseconds(200) else { return }
                lastRemoteMediaCommand = now
                MacMediaKeyController.togglePlayPause()
            }

        default:
            break
        }
    }

    nonisolated func rejectForPairing() {
        guard let connection,
              let payload = try? JSONSerialization.data(withJSONObject: ["type": "pairing_required"]) else { return }
        var body = Data([Self.jsonPacket])
        body.append(payload)
        var record = Data()
        record.appendBigEndian(UInt32(body.count))
        record.append(body)
        connection.send(content: record, completion: .contentProcessed { [weak self, weak connection] _ in
            guard let self, let connection, connection === self.connection else { return }
            fail("Pairing required. Enter the TV’s code on the Mac, then Connect on the TV.")
        })
    }

    nonisolated static func deriveKey(code: String, salt: Data) -> Data? {
        var derived = Data(count: 32)
        let status = code.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { derivedBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password,
                        code.lengthOfBytes(using: .utf8),
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        120_000,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        32
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    nonisolated static func deriveRememberedSessionKey(
        secret: Data,
        salt: Data,
        serverChallenge: Data,
        clientChallenge: Data
    ) -> Data {
        var message = Data("session".utf8)
        message.append(salt)
        message.append(serverChallenge)
        message.append(clientChallenge)
        return Data(HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: secret)
        ))
    }

    nonisolated static func deriveTrustSecret(
        key: SymmetricKey,
        serverChallenge: Data,
        clientChallenge: Data
    ) -> Data {
        var message = Data("remember-receiver".utf8)
        message.append(serverChallenge)
        message.append(clientChallenge)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    nonisolated static func authenticationCode(
        key: SymmetricKey,
        label: String,
        serverChallenge: Data,
        clientChallenge: Data
    ) -> Data {
        var message = Data(label.utf8)
        message.append(serverChallenge)
        message.append(clientChallenge)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    nonisolated static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    nonisolated static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

}
#endif
