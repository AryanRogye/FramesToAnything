//
//  PairingService.swift
//  macOSFramesToFireTV
//
//  Created by Aryan Rogye on 8/8/26.
//

#if os(iOS)

import CommonCrypto
import CryptoKit
import Foundation
import Network
import Security

/// Discovers the Mac sender, authenticates it with the displayed pairing code,
/// and turns the encrypted TCP stream into decoded media packet callbacks.
nonisolated final class PairingService: @unchecked Sendable {
    typealias PairingCodeHandler = @MainActor @Sendable (String) -> Void
    typealias PairingRequestHandler = @MainActor @Sendable (String?) -> Void
    typealias StatusHandler = @MainActor @Sendable (_ message: String, _ streaming: Bool) -> Void
    typealias VideoConfigurationHandler = @MainActor @Sendable (
        _ width: Int,
        _ height: Int,
        _ rotationDegrees: Int,
        _ sps: Data,
        _ pps: Data
    ) -> Void
    typealias VideoFrameHandler = @MainActor @Sendable (
        _ data: Data,
        _ timestampMilliseconds: Int64,
        _ isKeyFrame: Bool
    ) -> Void
    typealias AudioConfigurationHandler = @MainActor @Sendable (
        _ sampleRate: Int,
        _ channels: Int,
        _ encoding: Int,
        _ codecConfiguration: Data
    ) -> Void
    typealias AudioFrameHandler = @MainActor @Sendable (Data, Int64) -> Void
    typealias MediaEndedHandler = @MainActor @Sendable () -> Void

    private let queue = DispatchQueue(
        label: "com.aryanrogye.macframes.ios.pairing",
        qos: .userInteractive
    )

    private var browser: NWBrowser?
    private var advertisementListener: NWListener?
    private var connection: NWConnection?
    private var resolvedMac: NWEndpoint?
    private var receiveBuffer = Data()
    private var connectTimeout: DispatchWorkItem?

    private var running = false
    private var connecting = false
    private var resetRequested = false
    private var pairingCode = ""
    private var salt: Data?
    private var serverChallenge: Data?
    private var sessionKey: SymmetricKey?
    private var authenticated = false
    private var negotiatedFeatures = Set<String>()

    private let onPairingCode: PairingCodeHandler
    private let onPairingRequest: PairingRequestHandler
    private let onStatus: StatusHandler
    private let onVideoConfiguration: VideoConfigurationHandler
    private let onVideoFrame: VideoFrameHandler
    private let onAudioConfiguration: AudioConfigurationHandler
    private let onAudioFrame: AudioFrameHandler
    private let onMediaEnded: MediaEndedHandler
    private let receiverServiceName: String

    init(
        receiverServiceName: String,
        onPairingCode: @escaping PairingCodeHandler,
        onPairingRequest: @escaping PairingRequestHandler = { _ in },
        onStatus: @escaping StatusHandler,
        onVideoConfiguration: @escaping VideoConfigurationHandler = { _, _, _, _, _ in },
        onVideoFrame: @escaping VideoFrameHandler = { _, _, _ in },
        onAudioConfiguration: @escaping AudioConfigurationHandler = { _, _, _, _ in },
        onAudioFrame: @escaping AudioFrameHandler = { _, _ in },
        onMediaEnded: @escaping MediaEndedHandler = {}
    ) {
        self.receiverServiceName = receiverServiceName
        self.onPairingCode = onPairingCode
        self.onPairingRequest = onPairingRequest
        self.onStatus = onStatus
        self.onVideoConfiguration = onVideoConfiguration
        self.onVideoFrame = onVideoFrame
        self.onAudioConfiguration = onAudioConfiguration
        self.onAudioFrame = onAudioFrame
        self.onMediaEnded = onMediaEnded
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !running else { return }
            running = true
            rotatePairingCode()
            advertiseReceiver()
            reportStatus("Looking for a Mac…", streaming: false)
            discoverMacSender()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            running = false
            connectTimeout?.cancel()
            connectTimeout = nil
            browser?.cancel()
            browser = nil
            advertisementListener?.cancel()
            advertisementListener = nil
            resolvedMac = nil
            if let connection {
                finishConnection(connection, reconnect: false, reportEnded: authenticated)
            }
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self, running else { return }
            resetRequested = connection != nil
            if let connection {
                finishConnection(connection, reconnect: true, reportEnded: authenticated)
            }
            rotatePairingCode()
            reportStatus("Ready to pair — session reset", streaming: false)
        }
    }

    private func discoverMacSender() {
        browser?.cancel()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: Self.macServiceType, domain: nil),
            using: parameters
        )
        self.browser = browser

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, browser === self.browser, running else { return }
            switch state {
            case .failed(let error):
                reportStatus("Mac discovery unavailable: \(error.localizedDescription)", streaming: false)
            case .waiting:
                reportStatus("Waiting for local-network access…", streaming: false)
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, running else { return }
            let matchingResults = results.filter { result in
                guard let target = Self.txtValue("target", from: result) else {
                    return true
                }
                return target == Self.receiverID
            }
            guard let endpoint = matchingResults
                .map(\.endpoint)
                .sorted(by: { String(describing: $0) < String(describing: $1) })
                .first else {
                resolvedMac = nil
                return
            }
            guard resolvedMac != endpoint || connection == nil else { return }
            resolvedMac = endpoint
            connect(to: endpoint)
        }
        browser.start(queue: queue)
    }

    private func advertiseReceiver() {
        advertisementListener?.cancel()
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = .init(
                name: receiverServiceName,
                type: "_iosfiretv._tcp",
                txtRecord: NWTXTRecord([
                    "id": Self.receiverID,
                    "kind": "ios",
                ])
            )
            listener.newConnectionHandler = { connection in connection.cancel() }
            advertisementListener = listener
            listener.start(queue: queue)
        } catch {
            reportStatus("Receiver discovery unavailable: \(error.localizedDescription)", streaming: false)
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        guard running, !connecting, connection == nil else { return }
        connecting = true
        reportStatus("Connecting to Mac…", streaming: false)

        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, connection === self.connection else { return }
            switch state {
            case .ready:
                connectTimeout?.cancel()
                connectTimeout = nil
                connecting = false
                beginHandshake(on: connection)
            case .failed(let error):
                if running && !resetRequested {
                    reportStatus("Waiting for the Mac… (\(error.localizedDescription))", streaming: false)
                }
                finishConnection(connection, reconnect: true, reportEnded: authenticated)
            case .cancelled:
                // Explicit cancellation is finalized by stop/reset/failure.
                break
            default:
                break
            }
        }

        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, connection === self.connection, connecting else { return }
            reportStatus("Waiting for the Mac…", streaming: false)
            finishConnection(connection, reconnect: true, reportEnded: false)
        }
        connectTimeout = timeout
        queue.asyncAfter(
            deadline: .now() + .milliseconds(Self.connectTimeoutMilliseconds),
            execute: timeout
        )
        connection.start(queue: queue)
    }

    private func beginHandshake(on connection: NWConnection) {
        clearSession()
        reportPairingRequest(nil)

        let salt = Self.randomData(count: 16)
        let challenge = Self.randomData(count: 32)
        self.salt = salt
        serverChallenge = challenge

        sendJSON(
            [
                "type": "hello",
                "version": 1,
                "receiverID": Self.receiverID,
                "features": Array(Self.cinemaFeatures).sorted(),
                "salt": salt.base64EncodedString(),
                "challenge": challenge.base64EncodedString(),
            ],
            on: connection
        ) { [weak self, weak connection] error in
            guard let self, let connection, connection === self.connection else { return }
            if let error {
                fail(connection, message: "Could not start pairing: \(error.localizedDescription)")
            } else {
                receiveNextChunk(from: connection)
            }
        }
    }

    private func receiveNextChunk(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, connection === self.connection else { return }
            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                do {
                    try processPackets(from: connection)
                } catch {
                    fail(connection, message: "Connection ended: \(error.localizedDescription)")
                    return
                }
            }
            if let error {
                fail(connection, message: "Connection ended: \(error.localizedDescription)")
            } else if isComplete {
                finishConnection(connection, reconnect: true, reportEnded: authenticated)
            } else {
                receiveNextChunk(from: connection)
            }
        }
    }

    private func processPackets(from connection: NWConnection) throws {
        while receiveBuffer.count >= 4 {
            let length = receiveBuffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length >= 1, length <= Self.maximumFramePacketBytes else {
                throw PairingError.invalidPacketSize
            }
            let fullLength = 4 + Int(length)
            guard receiveBuffer.count >= fullLength else { return }
            let record = receiveBuffer.subdata(in: 4..<fullLength)
            receiveBuffer.removeSubrange(0..<fullLength)
            guard let type = record.first else { throw PairingError.invalidPacketSize }
            let payload = record.dropFirst()

            switch type {
            case Self.jsonPacket:
                guard !authenticated, length <= Self.maximumJSONPacketBytes else {
                    throw PairingError.unexpectedJSON
                }
                try handleJSON(Data(payload), from: connection)
            case Self.encryptedMediaPacket:
                guard authenticated, let sessionKey else { throw PairingError.mediaBeforeAuthentication }
                try handleEncryptedMedia(Data(payload), key: sessionKey)
            default:
                continue
            }
        }
    }

    private func handleJSON(_ data: Data, from connection: NWConnection) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "auth" else {
            throw PairingError.expectedAuthentication
        }
        let deviceName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let senderID = (json["senderID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = json["mode"] as? String ?? "code"
        reportPairingRequest(deviceName?.isEmpty == false ? deviceName : nil)

        guard let challengeValue = json["challenge"] as? String,
              let proofValue = json["proof"] as? String,
              let clientChallenge = Data(base64Encoded: challengeValue),
              let suppliedProof = Data(base64Encoded: proofValue),
              clientChallenge.count == 32,
              let salt,
              let serverChallenge else {
            throw PairingError.invalidAuthentication
        }

        let keyData: Data?
        if mode == "remembered", let senderID, let secret = TrustedSenderStore.load(senderID) {
            keyData = Self.deriveRememberedSessionKey(
                secret: secret,
                salt: salt,
                serverChallenge: serverChallenge,
                clientChallenge: clientChallenge
            )
        } else if mode == "code" {
            keyData = Self.deriveKey(code: pairingCode, salt: salt)
        } else {
            keyData = nil
        }
        guard let keyData else {
            sendAuthenticationFailure(on: connection, remembered: mode == "remembered")
            return
        }
        let key = SymmetricKey(data: keyData)
        let expectedProof = Self.authenticationCode(
            key: key,
            label: "client",
            serverChallenge: serverChallenge,
            clientChallenge: clientChallenge
        )
        guard Self.constantTimeEqual(suppliedProof, expectedProof) else {
            sendAuthenticationFailure(on: connection, remembered: mode == "remembered")
            return
        }

        if mode == "code", let senderID, !senderID.isEmpty {
            let trustSecret = Self.deriveTrustSecret(
                key: key,
                serverChallenge: serverChallenge,
                clientChallenge: clientChallenge
            )
            TrustedSenderStore.save(trustSecret, for: senderID)
        }

        let acceptedFeatures = Set(json["acceptedFeatures"] as? [String] ?? [])
        negotiatedFeatures = acceptedFeatures.intersection(Self.cinemaFeatures)
        let serverProof = Self.authenticationCode(
            key: key,
            label: "server",
            serverChallenge: serverChallenge,
            clientChallenge: clientChallenge
        )
        // Install the key before sending auth_ok. If the Mac responds with its
        // first media record immediately, the record can be processed safely.
        sessionKey = key
        authenticated = true
        sendJSON(
            [
                "type": "auth_ok",
                "proof": serverProof.base64EncodedString(),
                "acceptedFeatures": Array(
                    negotiatedFeatures
                ).sorted(),
            ],
            on: connection
        ) { [weak self, weak connection] error in
            guard let self, let connection, connection === self.connection else { return }
            if let error {
                fail(connection, message: "Could not finish pairing: \(error.localizedDescription)")
                return
            }
            reportStatus("Streaming display and audio", streaming: true)
        }
    }

    private func sendAuthenticationFailure(on connection: NWConnection, remembered: Bool) {
        sendJSON(
            ["type": "auth_failed", "reason": remembered ? "forgotten" : "code"],
            on: connection
        ) { [weak self, weak connection] _ in
            guard let self, let connection, connection === self.connection else { return }
            reportStatus(
                remembered ? "This Mac needs to pair again" : "Incorrect pairing code",
                streaming: false
            )
            finishConnection(connection, reconnect: true, reportEnded: false)
        }
    }

    private func handleEncryptedMedia(_ payload: Data, key: SymmetricKey) throws {
        guard payload.count > Self.gcmNonceBytes + 16 else { throw PairingError.encryptedFrameTooShort }
        let sealedBox = try AES.GCM.SealedBox(combined: payload)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        guard plaintext.count >= Self.mediaHeaderBytes,
              plaintext[plaintext.startIndex] == Self.mediaVersion else {
            throw PairingError.invalidMediaPacket
        }

        let kind = plaintext[plaintext.startIndex + 1]
        let timestamp = plaintext
            .subdata(in: (plaintext.startIndex + 2)..<(plaintext.startIndex + 10))
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let isKeyFrame = plaintext[plaintext.startIndex + 10] != 0
        let media = plaintext.subdata(in: (plaintext.startIndex + Self.mediaHeaderBytes)..<plaintext.endIndex)

        switch kind {
        case Self.mediaVideoConfiguration:
            try parseVideoConfiguration(media)
        case Self.mediaVideoFrame:
            reportVideoFrame(media, timestamp: Int64(bitPattern: timestamp), isKeyFrame: isKeyFrame)
        case Self.mediaAudioConfiguration:
            try parseAudioConfiguration(media)
        case Self.mediaAudioFrame:
            reportAudioFrame(media, timestamp: Int64(bitPattern: timestamp))
        default:
            break
        }
    }

    private func parseVideoConfiguration(_ data: Data) throws {
        var reader = DataReader(data: data)
        let width = Int(try reader.readUInt16())
        let height = Int(try reader.readUInt16())
        let rotation = Int(try reader.readUInt16())
        let sps = try reader.readData(count: Int(try reader.readUInt16()), requireNonempty: true)
        let pps = try reader.readData(count: Int(try reader.readUInt16()), requireNonempty: true)
        guard reader.isAtEnd else { throw PairingError.invalidVideoConfiguration }
        reportVideoConfiguration(width: width, height: height, rotation: rotation, sps: sps, pps: pps)
    }

    private func parseAudioConfiguration(_ data: Data) throws {
        var reader = DataReader(data: data)
        let sampleRate = Int(try reader.readUInt32())
        let channels = Int(try reader.readUInt8())
        let encoding = try reader.readUInt8()
        let codecConfiguration = try reader.readRemainingData()
        guard (8_000...192_000).contains(sampleRate),
              (1...2).contains(channels),
              (encoding == Self.audioPCM16 || encoding == Self.audioAACLC),
              encoding == Self.audioPCM16 || !codecConfiguration.isEmpty else {
            throw PairingError.unsupportedAudioConfiguration
        }
        reportAudioConfiguration(
            sampleRate: sampleRate,
            channels: channels,
            encoding: encoding,
            codecConfiguration: codecConfiguration
        )
    }

    func sendReceiverReport(_ report: iOSCinemaPlaybackReport) {
        queue.async { [weak self] in
            guard let self,
                  authenticated,
                  negotiatedFeatures.contains("receiver-report-v1"),
                  let connection else { return }
            sendJSON(
                [
                    "type": "receiver_report",
                    "version": 1,
                    "videoBufferMs": report.videoBufferMilliseconds,
                    "audioBufferMs": report.audioBufferMilliseconds,
                    "decoderBacklogMs": report.decoderBacklogMilliseconds,
                    "underruns": report.underruns,
                    "recoveries": report.recoveries,
                    "lastPresentedTimestampMs": report.lastPresentedTimestampMilliseconds,
                ],
                on: connection
            )
        }
    }

    func requestKeyFrame(reason: String, lastPresentedTimestampMilliseconds: Int64) {
        queue.async { [weak self] in
            guard let self,
                  authenticated,
                  negotiatedFeatures.contains("keyframe-request-v1"),
                  let connection else { return }
            sendJSON(
                [
                    "type": "request_keyframe",
                    "version": 1,
                    "reason": reason,
                    "lastPresentedTimestampMs": lastPresentedTimestampMilliseconds,
                ],
                on: connection
            )
        }
    }

    private func sendJSON(
        _ object: [String: Any],
        on connection: NWConnection,
        completion: @escaping @Sendable (NWError?) -> Void = { _ in }
    ) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
            completion(.posix(.EINVAL))
            return
        }
        var body = Data([Self.jsonPacket])
        body.append(payload)
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed(completion))
    }

    private func fail(_ connection: NWConnection, message: String) {
        guard connection === self.connection else { return }
        if running && !resetRequested {
            reportStatus(message, streaming: false)
        }
        finishConnection(connection, reconnect: true, reportEnded: authenticated)
    }

    private func finishConnection(
        _ connection: NWConnection,
        reconnect: Bool,
        reportEnded: Bool
    ) {
        guard connection === self.connection else { return }
        connectTimeout?.cancel()
        connectTimeout = nil
        self.connection = nil
        connecting = false
        connection.stateUpdateHandler = nil
        connection.cancel()

        if reportEnded { reportMediaEnded() }
        let completedTCPConnection = salt != nil
        clearSession()

        let wasReset = resetRequested
        resetRequested = false
        if running && !wasReset && completedTCPConnection {
            rotatePairingCode()
            reportStatus("Looking for a Mac…", streaming: false)
        }
        if reconnect, running, let endpoint = resolvedMac {
            queue.asyncAfter(deadline: .now() + .milliseconds(Self.reconnectDelayMilliseconds)) {
                [weak self] in
                guard let self, running, resolvedMac == endpoint, self.connection == nil else { return }
                connect(to: endpoint)
            }
        }
    }

    private func clearSession() {
        receiveBuffer.removeAll(keepingCapacity: true)
        salt = nil
        serverChallenge = nil
        sessionKey = nil
        authenticated = false
        negotiatedFeatures.removeAll(keepingCapacity: true)
    }

    private func rotatePairingCode() {
        pairingCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let callback = onPairingCode
        Task { @MainActor in callback(pairingCode) }
    }

    private func reportPairingRequest(_ name: String?) {
        let callback = onPairingRequest
        Task { @MainActor in callback(name) }
    }

    private func reportStatus(_ message: String, streaming: Bool) {
        let callback = onStatus
        Task { @MainActor in callback(message, streaming) }
    }

    private func reportVideoConfiguration(
        width: Int,
        height: Int,
        rotation: Int,
        sps: Data,
        pps: Data
    ) {
        let callback = onVideoConfiguration
        Task { @MainActor in callback(width, height, rotation, sps, pps) }
    }

    private func reportVideoFrame(_ data: Data, timestamp: Int64, isKeyFrame: Bool) {
        let callback = onVideoFrame
        Task { @MainActor in callback(data, timestamp, isKeyFrame) }
    }

    private func reportAudioConfiguration(
        sampleRate: Int,
        channels: Int,
        encoding: UInt8,
        codecConfiguration: Data
    ) {
        let callback = onAudioConfiguration
        Task { @MainActor in
            callback(sampleRate, channels, Int(encoding), codecConfiguration)
        }
    }

    private func reportAudioFrame(_ data: Data, timestamp: Int64) {
        let callback = onAudioFrame
        Task { @MainActor in callback(data, timestamp) }
    }

    private func reportMediaEnded() {
        let callback = onMediaEnded
        Task { @MainActor in callback() }
    }

    private static func deriveKey(code: String, salt: Data) -> Data? {
        let derivedByteCount = 32
        var derived = Data(count: derivedByteCount)
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
                        UInt32(Self.pbkdf2Iterations),
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedByteCount
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    private static func deriveRememberedSessionKey(
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

    private static func deriveTrustSecret(
        key: SymmetricKey,
        serverChallenge: Data,
        clientChallenge: Data
    ) -> Data {
        var message = Data("remember-receiver".utf8)
        message.append(serverChallenge)
        message.append(clientChallenge)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    private static func txtValue(_ key: String, from result: NWBrowser.Result) -> String? {
        guard case .bonjour(let record) = result.metadata,
              case .string(let value) = record.getEntry(for: key),
              !value.isEmpty else { return nil }
        return value
    }

    private static let receiverID: String = {
        let key = "discovery.receiverID"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

    private static func authenticationCode(
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

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func randomData(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

    private enum PairingError: LocalizedError {
        case invalidPacketSize
        case unexpectedJSON
        case mediaBeforeAuthentication
        case expectedAuthentication
        case invalidAuthentication
        case encryptedFrameTooShort
        case invalidMediaPacket
        case truncatedMediaData
        case invalidVideoConfiguration
        case unsupportedAudioConfiguration

        var errorDescription: String? {
            switch self {
            case .invalidPacketSize: "Invalid packet size"
            case .unexpectedJSON: "Unexpected pairing message"
            case .mediaBeforeAuthentication: "Media arrived before authentication"
            case .expectedAuthentication: "Expected authentication"
            case .invalidAuthentication: "Invalid authentication data"
            case .encryptedFrameTooShort: "Encrypted frame is too short"
            case .invalidMediaPacket: "Invalid media packet"
            case .truncatedMediaData: "Truncated media data"
            case .invalidVideoConfiguration: "Invalid video configuration"
            case .unsupportedAudioConfiguration: "Unsupported audio configuration"
            }
        }
    }

    private struct DataReader {
        let data: Data
        var offset = 0

        var isAtEnd: Bool { offset == data.count }

        mutating func readUInt8() throws -> UInt8 {
            guard offset < data.count else { throw PairingError.truncatedMediaData }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func readUInt16() throws -> UInt16 {
            let bytes = try readData(count: 2)
            return bytes.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        }

        mutating func readUInt32() throws -> UInt32 {
            let bytes = try readData(count: 4)
            return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        mutating func readData(count: Int, requireNonempty: Bool = false) throws -> Data {
            guard count >= 0,
                  (!requireNonempty || count > 0),
                  count <= data.count - offset else {
                throw PairingError.truncatedMediaData
            }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func readRemainingData() throws -> Data {
            try readData(count: data.count - offset)
        }
    }

    private static let macServiceType = "_framesmac._tcp"
    private static let jsonPacket: UInt8 = 0
    private static let encryptedMediaPacket: UInt8 = 2
    private static let mediaVersion: UInt8 = 2
    private static let mediaHeaderBytes = 11
    private static let mediaVideoConfiguration: UInt8 = 1
    private static let mediaVideoFrame: UInt8 = 2
    private static let mediaAudioConfiguration: UInt8 = 3
    private static let mediaAudioFrame: UInt8 = 4
    private static let audioPCM16: UInt8 = 1
    private static let audioAACLC: UInt8 = 2
    private static let gcmNonceBytes = 12
    private static let pbkdf2Iterations = 120_000
    private static let connectTimeoutMilliseconds = 5_000
    private static let reconnectDelayMilliseconds = 1_500
    private static let maximumJSONPacketBytes: UInt32 = 64 * 1024
    private static let maximumFramePacketBytes: UInt32 = 8 * 1024 * 1024
    private static let cinemaFeatures: Set<String> = [
        "cinema-buffer-v1",
        "receiver-report-v1",
        "keyframe-request-v1",
        "aac-lc-v1",
    ]
}

private enum TrustedSenderStore {
    private static let service = "com.aryanrogye.iOSFramesReceiver.remembered-senders"

    static func load(_ senderID: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: senderID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    static func save(_ secret: Data, for senderID: String) {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: senderID,
        ]
        let attributes = [kSecValueData as String: secret]
        if SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = secret
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

#endif
