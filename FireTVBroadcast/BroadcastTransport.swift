import CommonCrypto
import CoreMedia
import CryptoKit
import ImageIO
import Network
import ReplayKit
import Security
import SnapCore

struct BroadcastConfiguration: Sendable {
    let serviceName: String?
    let manualHost: String?
    let pairingCode: String

    static func load() -> BroadcastConfiguration? {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let pairingCode = defaults.string(forKey: pairingCodeKey),
              pairingCode.count == 6 else {
            return nil
        }
        let serviceName = defaults.string(forKey: serviceNameKey)
        let manualHost = defaults.string(forKey: manualHostKey)
        guard serviceName?.isEmpty == false || manualHost?.isEmpty == false else {
            return nil
        }
        return BroadcastConfiguration(
            serviceName: serviceName,
            manualHost: manualHost,
            pairingCode: pairingCode
        )
    }

    private static let appGroup = "group.com.aryanrogye.iOSFramesToFireTV"
    private static let serviceNameKey = "broadcast.serviceName"
    private static let manualHostKey = "broadcast.manualHost"
    private static let pairingCodeKey = "broadcast.pairingCode"
}

/// A self-contained sender owned by the ReplayKit extension process. The host
/// app can be suspended without affecting this connection.
nonisolated final class BroadcastTransport: @unchecked Sendable {
    var onFailure: (@Sendable (String) -> Void)?
    var isPaused = false

    private let configuration: BroadcastConfiguration
    private let networkQueue = DispatchQueue(label: "com.aryanrogye.firetv.broadcast.network")
    private let keyLock = NSLock()

    private let mediaEncoder: LiveMediaEncoder

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var discoveryTimeout: DispatchWorkItem?
    private var receiveBuffer = Data()
    private var serverChallenge: Data?
    private var clientChallenge: Data?
    private var handshakeKey: SymmetricKey?
    private var streamingKey: SymmetricKey?
    private var writeInFlight = false
    private var pendingPackets: [QueuedPacket] = []
    private var latestVideoPacket: Data?
    private var stopped = false

    init(configuration: BroadcastConfiguration) {
        self.configuration = configuration
        let encoder = LiveMediaEncoder(
            configuration: .init(
                framesPerSecond: 60,
                averageBitRate: 10_000_000,
                keyFrameInterval: 60
            )
        )
        mediaEncoder = encoder
        encoder.onPacket = { [weak self] packet in
            self?.sendMedia(packet)
        }
        encoder.onError = { [weak self] message in
            self?.networkQueue.async { [weak self] in self?.fail(message) }
        }
    }

    func start() {
        networkQueue.async { [weak self] in
            self?.beginDiscovery()
        }
    }

    func stop() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            stopped = true
            discoveryTimeout?.cancel()
            browser?.cancel()
            connection?.cancel()
            browser = nil
            connection = nil
            mediaEncoder.stop()
            clearSession()
        }
    }

    func send(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        guard !isPaused, currentStreamingKey() != nil else { return }
        switch type {
        case .video:
            mediaEncoder.encodeVideo(
                sampleBuffer,
                rotationDegrees: Self.videoRotationDegrees(from: sampleBuffer)
            )
        case .audioApp:
            // App audio is the sound users expect to hear on the Fire TV.
            mediaEncoder.encodeAudio(sampleBuffer)
        case .audioMic:
            // The microphone is intentionally not mixed into streamed content.
            break
        @unknown default:
            break
        }
    }

    private func sendMedia(_ packet: LiveMediaPacket) {
        guard let key = currentStreamingKey() else { return }
        var plaintext = Data([Self.mediaVersion, packet.kind.rawValue])
        var timestamp = packet.timestampMilliseconds.bigEndian
        withUnsafeBytes(of: &timestamp) { plaintext.append(contentsOf: $0) }
        plaintext.append(packet.isKeyFrame ? 1 : 0)
        plaintext.append(packet.payload)

        guard let sealed = try? AES.GCM.seal(plaintext, using: key),
              let encrypted = sealed.combined else {
            return
        }
        let kind: QueuedPacket.Kind
        switch packet.kind {
        case .videoFrame:
            kind = .video
        case .audioFrame:
            kind = .audio
        case .videoConfiguration, .audioConfiguration:
            kind = .control
        }
        sendPacket(type: Self.encryptedMediaPacket, payload: encrypted, kind: kind)
    }

    private func beginDiscovery() {
        guard !stopped else { return }

        if let manualHost = configuration.manualHost, !manualHost.isEmpty {
            connect(
                to: .hostPort(
                    host: NWEndpoint.Host(manualHost),
                    port: NWEndpoint.Port(rawValue: 49_218)!
                )
            )
            return
        }

        let browser = NWBrowser(
            for: .bonjour(type: "_iosfiretv._tcp", domain: nil),
            using: .tcp
        )
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.fail("Fire TV discovery failed: \(error.localizedDescription)")
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            guard let endpoint = results.first(where: { result in
                guard case .service(let name, _, _, _) = result.endpoint else {
                    return false
                }
                return name == self.configuration.serviceName
            })?.endpoint else {
                return
            }
            self.discoveryTimeout?.cancel()
            browser.cancel()
            self.browser = nil
            self.connect(to: endpoint)
        }
        browser.start(queue: networkQueue)

        let timeout = DispatchWorkItem { [weak self] in
            self?.fail("The selected Fire TV was not found on this Wi-Fi network.")
        }
        self.discoveryTimeout = timeout
        self.networkQueue.asyncAfter(deadline: .now() + 15, execute: timeout)
    }

    private func connect(to endpoint: NWEndpoint) {
        guard !stopped else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, connection === self.connection else { return }
            switch state {
            case .ready:
                receiveNextChunk()
            case .failed(let error):
                fail("Fire TV connection failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    private func receiveNextChunk() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self, !stopped else { return }
            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                processPackets()
            }
            if let error {
                fail("Fire TV connection ended: \(error.localizedDescription)")
                return
            }
            if isComplete {
                fail("The Fire TV ended the broadcast connection.")
                return
            }
            receiveNextChunk()
        }
    }

    private func processPackets() {
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

    private func handleJSON(_ bytes: Data.SubSequence) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let type = object["type"] as? String else {
            fail("The Fire TV sent an unreadable authentication message.")
            return
        }

        switch type {
        case "hello":
            guard (object["version"] as? Int) == 1,
                  let saltString = object["salt"] as? String,
                  let challengeString = object["challenge"] as? String,
                  let salt = Data(base64Encoded: saltString),
                  let serverChallenge = Data(base64Encoded: challengeString),
                  serverChallenge.count == 32,
                  let keyData = Self.deriveKey(
                    code: configuration.pairingCode,
                    salt: salt
                  ) else {
                fail("The Fire TV uses an unsupported authentication protocol.")
                return
            }

            let clientChallenge = Self.randomData(count: 32)
            let key = SymmetricKey(data: keyData)
            self.serverChallenge = serverChallenge
            self.clientChallenge = clientChallenge
            handshakeKey = key

            let proof = Self.authenticationCode(
                key: key,
                label: "client",
                serverChallenge: serverChallenge,
                clientChallenge: clientChallenge
            )
            sendJSON([
                "type": "auth",
                "challenge": clientChallenge.base64EncodedString(),
                "proof": proof.base64EncodedString(),
            ])

        case "auth_ok":
            guard let proofString = object["proof"] as? String,
                  let suppliedProof = Data(base64Encoded: proofString),
                  let key = handshakeKey,
                  let serverChallenge,
                  let clientChallenge else {
                fail("The Fire TV did not complete authentication.")
                return
            }
            let expectedProof = Self.authenticationCode(
                key: key,
                label: "server",
                serverChallenge: serverChallenge,
                clientChallenge: clientChallenge
            )
            guard Self.constantTimeEqual(suppliedProof, expectedProof) else {
                fail("The Fire TV identity check failed.")
                return
            }
            setStreamingKey(key)

        case "auth_failed":
            fail("The Fire TV rejected the pairing code. Reopen the sender app and enter the new TV code.")

        default:
            break
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        sendPacket(type: Self.jsonPacket, payload: data, kind: .control)
    }

    private func sendPacket(type: UInt8, payload: Data, kind: QueuedPacket.Kind) {
        var body = Data([type])
        body.append(payload)
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(body)

        networkQueue.async { [weak self] in
            guard let self,
                  !stopped,
                  let connection else {
                return
            }
            self.enqueue(packet, kind: kind, connection: connection)
        }
    }

    private func enqueue(_ packet: Data, kind: QueuedPacket.Kind, connection: NWConnection) {
        if writeInFlight {
            if kind == .video {
                latestVideoPacket = packet
            } else {
                if pendingPackets.count >= Self.maximumPendingPackets,
                   let staleAudio = pendingPackets.firstIndex(where: { $0.kind == .audio }) {
                    pendingPackets.remove(at: staleAudio)
                }
                pendingPackets.append(QueuedPacket(data: packet, kind: kind))
            }
            return
        }
        write(packet, using: connection)
    }

    private func write(_ packet: Data, using connection: NWConnection) {
        writeInFlight = true
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.writeInFlight = false
            if let error {
                self.fail("Could not send media: \(error.localizedDescription)")
                return
            }
            if !self.pendingPackets.isEmpty {
                let next = self.pendingPackets.removeFirst()
                self.write(next.data, using: connection)
            } else if let latest = self.latestVideoPacket {
                self.latestVideoPacket = nil
                self.write(latest, using: connection)
            }
        })
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stopped = true
        discoveryTimeout?.cancel()
        browser?.cancel()
        connection?.cancel()
        clearSession()
        onFailure?(message)
    }

    private func clearSession() {
        receiveBuffer.removeAll(keepingCapacity: true)
        serverChallenge = nil
        clientChallenge = nil
        handshakeKey = nil
        writeInFlight = false
        pendingPackets.removeAll(keepingCapacity: true)
        latestVideoPacket = nil
        setStreamingKey(nil)
    }

    private func currentStreamingKey() -> SymmetricKey? {
        keyLock.withLock { streamingKey }
    }

    private func setStreamingKey(_ key: SymmetricKey?) {
        keyLock.withLock { streamingKey = key }
    }

    private static func deriveKey(code: String, salt: Data) -> Data? {
        let passwordLength = code.lengthOfBytes(using: .utf8)
        let derivedCount = 32
        var derived = Data(count: derivedCount)
        let status = code.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { derivedBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password,
                        passwordLength,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        120_000,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedCount
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

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

    private static func videoRotationDegrees(
        from sampleBuffer: CMSampleBuffer
    ) -> UInt16 {
        guard let value = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else {
            return 0
        }
        return switch orientation {
        case .down, .downMirrored: 180
        case .left, .leftMirrored: 90
        case .right, .rightMirrored: 270
        default: 0
        }
    }

    private struct QueuedPacket {
        enum Kind: Equatable { case control, audio, video }
        let data: Data
        let kind: Kind
    }

    private static let jsonPacket: UInt8 = 0
    private static let encryptedMediaPacket: UInt8 = 2
    private static let mediaVersion: UInt8 = 2
    private static let maximumJSONPacketBytes: UInt32 = 64 * 1024
    private static let maximumPendingPackets = 24
}
