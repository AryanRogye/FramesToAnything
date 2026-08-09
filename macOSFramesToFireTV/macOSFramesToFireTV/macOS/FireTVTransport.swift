#if os(macOS)
import CommonCrypto
import CoreMedia
import CryptoKit
import Foundation
import Network
import OSLog
import Security
import SnapCore

private let macTransportLogger = Logger(
    subsystem: "com.aryanrogye.macOSFramesToFireTV",
    category: "MediaTransport"
)

struct MacFireTVDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

enum MacFireTVConnectionState: Sendable, Equatable {
    case searching
    case waitingForReceiver
    case connecting(String)
    case authenticating
    case connected(String)
    case failed(String)
    case disconnected

    var message: String {
        switch self {
        case .searching: "Searching for Fire TV receivers…"
        case .waitingForReceiver: "Waiting for the Fire TV to connect…"
        case .connecting(let name): "Connecting to \(name)…"
        case .authenticating: "Checking the pairing code…"
        case .connected(let name): "Securely connected to \(name)"
        case .failed(let message): message
        case .disconnected: "Not connected"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Authenticated, encrypted, freshness-first media transport shared by the
/// macOS capture callbacks.
nonisolated final class MacFireTVTransport: @unchecked Sendable {
    var onDevicesChanged: (@MainActor @Sendable ([MacFireTVDevice]) -> Void)?
    var onStateChanged: (@MainActor @Sendable (MacFireTVConnectionState) -> Void)?

    private let networkQueue = DispatchQueue(
        label: "com.aryanrogye.firetv.mac.network",
        qos: .userInteractive
    )
    private let keyLock = NSLock()
    private let mediaEncoder: LiveMediaEncoder

    init() {
        let encoder = LiveMediaEncoder(
            configuration: .init(
                framesPerSecond: 60,
                averageBitRate: 10_000_000,
                keyFrameInterval: 30
            )
        )
        mediaEncoder = encoder
        encoder.onPacket = { [weak self] packet in self?.sendMedia(packet) }
        encoder.onError = { [weak self] message in
            self?.networkQueue.async { [weak self] in self?.fail(message) }
        }
    }

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pairingCode = ""
    private var connectedName = "Fire TV"
    private var serverChallenge: Data?
    private var clientChallenge: Data?
    private var handshakeKey: SymmetricKey?
    private var streamingKey: SymmetricKey?
    private var writeInFlight = false
    private var pendingPackets: [QueuedPacket] = []
    private var waitingForCleanVideoFrame = false

    func startDiscovery() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            browser?.cancel()
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjour(type: "_iosfiretv._tcp", domain: nil),
                using: parameters
            )
            self.browser = browser
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.report(.searching)
                case .failed(let error):
                    self?.report(.failed("Discovery failed: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let devices = results.compactMap { result -> MacFireTVDevice? in
                    guard case .service(let name, _, _, _) = result.endpoint else {
                        return nil
                    }
                    return MacFireTVDevice(
                        id: String(describing: result.endpoint),
                        name: name,
                        endpoint: result.endpoint
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self?.publish(devices)
            }
            browser.start(queue: networkQueue)
        }
    }

    func connect(to device: MacFireTVDevice, code: String) {
        waitForFireTV(code: code)
    }

    /// Advertises a short-lived pairing listener. The Fire TV initiates the
    /// TCP connection, while the existing authenticated media protocol remains
    /// unchanged once the socket is accepted.
    func waitForFireTV(code: String) {
        let normalizedCode = code.filter(\.isNumber)
        guard normalizedCode.count == 6 else {
            report(.failed("Enter the six-digit code shown on the Fire TV."))
            return
        }
        networkQueue.async { [weak self] in
            guard let self else { return }
            connection?.cancel()
            listener?.cancel()
            clearSession()
            mediaEncoder.restart()
            pairingCode = normalizedCode
            connectedName = "Fire TV"

            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                if let tcpOptions = parameters.defaultProtocolStack.transportProtocol
                    as? NWProtocolTCP.Options {
                    tcpOptions.noDelay = true
                }
                let listener = try NWListener(using: parameters)
                listener.service = .init(
                    name: Host.current().localizedName ?? "Mac",
                    type: "_framesmac._tcp"
                )
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, listener === self.listener else { return }
                    switch state {
                    case .ready:
                        self.report(.waitingForReceiver)
                    case .failed(let error):
                        self.fail("Could not accept the Fire TV connection: \(error.localizedDescription)")
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    guard self.connection == nil else {
                        connection.cancel()
                        return
                    }
                    self.connection = connection
                    self.listener?.cancel()
                    self.listener = nil
                    self.report(.connecting("Fire TV"))
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        guard let self, connection === self.connection else { return }
                        switch state {
                        case .ready:
                            self.receiveNextChunk()
                        case .failed(let error):
                            self.fail("Connection failed: \(error.localizedDescription)")
                        case .cancelled:
                            self.report(.disconnected)
                        default:
                            break
                        }
                    }
                    connection.start(queue: self.networkQueue)
                }
                listener.start(queue: networkQueue)
            } catch {
                fail("Could not start the Mac receiver: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        networkQueue.async { [weak self] in
            guard let self else { return }
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
            mediaEncoder.stop()
            clearSession()
            report(.disconnected)
        }
    }

    func sendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard currentStreamingKey() != nil else { return }
        mediaEncoder.encodeVideo(sampleBuffer)
    }

    func sendVideo(_ imageBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard currentStreamingKey() != nil else { return }
        mediaEncoder.encodeVideo(imageBuffer, timestamp: timestamp)
    }

    func configureVideo(averageBitRate: Int) {
        mediaEncoder.updateConfiguration(
            .init(
                framesPerSecond: 60,
                averageBitRate: averageBitRate,
                keyFrameInterval: 30
            )
        )
    }

    func sendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard currentStreamingKey() != nil else { return }
        mediaEncoder.encodeAudio(sampleBuffer)
    }

    private func receiveNextChunk() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                processPackets()
            }
            if let error {
                fail("Connection ended: \(error.localizedDescription)")
            } else if isComplete {
                fail("The Fire TV ended the connection.")
            } else {
                receiveNextChunk()
            }
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
                  let saltValue = object["salt"] as? String,
                  let challengeValue = object["challenge"] as? String,
                  let salt = Data(base64Encoded: saltValue),
                  let serverChallenge = Data(base64Encoded: challengeValue),
                  serverChallenge.count == 32,
                  let keyData = Self.deriveKey(code: pairingCode, salt: salt) else {
                fail("The receiver uses an unsupported authentication protocol.")
                return
            }
            let clientChallenge = Self.randomData(count: 32)
            let key = SymmetricKey(data: keyData)
            self.serverChallenge = serverChallenge
            self.clientChallenge = clientChallenge
            handshakeKey = key
            report(.authenticating)
            let proof = Self.authenticationCode(
                key: key,
                label: "client",
                serverChallenge: serverChallenge,
                clientChallenge: clientChallenge
            )
            sendJSON([
                "type": "auth",
                "name": Host.current().localizedName ?? "Mac",
                "challenge": clientChallenge.base64EncodedString(),
                "proof": proof.base64EncodedString(),
            ])

        case "auth_ok":
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
            setStreamingKey(key)
            report(.connected(connectedName))

        case "auth_failed":
            fail("That pairing code was not accepted. The Fire TV has generated a new code.")
        default:
            break
        }
    }

    private func sendMedia(_ packet: LiveMediaPacket) {
        guard let key = currentStreamingKey() else { return }
        if packet.kind == .videoConfiguration {
            macTransportLogger.info("Encrypting and sending video configuration, \(packet.payload.count) bytes")
        }
        var plaintext = Data([Self.mediaVersion, packet.kind.rawValue])
        plaintext.appendBigEndian(packet.timestampMilliseconds)
        plaintext.append(packet.isKeyFrame ? 1 : 0)
        plaintext.append(packet.payload)
        guard let sealed = try? AES.GCM.seal(plaintext, using: key),
              let encrypted = sealed.combined else {
            return
        }
        let kind: QueuedPacket.Kind
        switch packet.kind {
        case .videoFrame: kind = .video
        case .audioFrame: kind = .audio
        case .videoConfiguration, .audioConfiguration: kind = .control
        }
        sendPacket(
            type: Self.encryptedMediaPacket,
            payload: encrypted,
            kind: kind,
            isKeyFrame: packet.isKeyFrame
        )
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        sendPacket(type: Self.jsonPacket, payload: payload, kind: .control)
    }

    private func sendPacket(
        type: UInt8,
        payload: Data,
        kind: QueuedPacket.Kind,
        isKeyFrame: Bool = false
    ) {
        var body = Data([type])
        body.append(payload)
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(body)
        networkQueue.async { [weak self] in
            guard let self, let connection else { return }
            enqueue(packet, kind: kind, isKeyFrame: isKeyFrame, connection: connection)
        }
    }

    private func enqueue(
        _ packet: Data,
        kind: QueuedPacket.Kind,
        isKeyFrame: Bool,
        connection: NWConnection
    ) {
        if writeInFlight {
            switch kind {
            case .video:
                if waitingForCleanVideoFrame {
                    guard isKeyFrame else { return }
                    // Preserve a recovery keyframe that is already queued. It
                    // must not be replaced before its TCP write completes.
                    if pendingPackets.contains(where: { $0.kind == .video && $0.isKeyFrame }) {
                        return
                    }
                    pendingPackets.removeAll { $0.kind == .video }
                    pendingPackets.append(
                        .init(data: packet, kind: kind, isKeyFrame: true)
                    )
                    return
                }
                if pendingPackets.contains(where: { $0.kind == .video }) {
                    pendingPackets.removeAll { $0.kind == .video }
                    waitingForCleanVideoFrame = true
                    if !isKeyFrame { return }
                }
                pendingPackets.append(
                    .init(data: packet, kind: kind, isKeyFrame: isKeyFrame)
                )
            case .audio:
                while pendingPackets.lazy.filter({ $0.kind == .audio }).count >= Self.maximumPendingAudioPackets,
                      let stale = pendingPackets.firstIndex(where: { $0.kind == .audio }) {
                    pendingPackets.remove(at: stale)
                }
                pendingPackets.append(.init(data: packet, kind: kind, isKeyFrame: false))
            case .control:
                pendingPackets.append(.init(data: packet, kind: kind, isKeyFrame: false))
            }
            return
        }
        write(.init(data: packet, kind: kind, isKeyFrame: isKeyFrame), using: connection)
    }

    private func write(_ packet: QueuedPacket, using connection: NWConnection) {
        writeInFlight = true
        connection.send(content: packet.data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            writeInFlight = false
            if let error {
                fail("Could not send media: \(error.localizedDescription)")
                return
            }
            if packet.kind == .video && packet.isKeyFrame {
                waitingForCleanVideoFrame = false
            }
            if !pendingPackets.isEmpty {
                write(pendingPackets.removeFirst(), using: connection)
            }
        })
    }

    private func fail(_ message: String) {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        clearSession()
        report(.failed(message))
    }

    private func clearSession() {
        receiveBuffer.removeAll(keepingCapacity: true)
        pairingCode = ""
        serverChallenge = nil
        clientChallenge = nil
        handshakeKey = nil
        writeInFlight = false
        pendingPackets.removeAll(keepingCapacity: true)
        waitingForCleanVideoFrame = false
        setStreamingKey(nil)
    }

    private func currentStreamingKey() -> SymmetricKey? {
        keyLock.withLock { streamingKey }
    }

    private func setStreamingKey(_ key: SymmetricKey?) {
        keyLock.withLock { streamingKey = key }
    }

    private func report(_ state: MacFireTVConnectionState) {
        let callback = onStateChanged
        Task { @MainActor in callback?(state) }
    }

    private func publish(_ devices: [MacFireTVDevice]) {
        let callback = onDevicesChanged
        Task { @MainActor in callback?(devices) }
    }

    private static func deriveKey(code: String, salt: Data) -> Data? {
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

    private struct QueuedPacket {
        enum Kind: Equatable { case control, audio, video }
        let data: Data
        let kind: Kind
        let isKeyFrame: Bool
    }

    private static let jsonPacket: UInt8 = 0
    private static let encryptedMediaPacket: UInt8 = 2
    private static let mediaVersion: UInt8 = 2
    private static let maximumJSONPacketBytes: UInt32 = 64 * 1024
    private static let maximumPendingAudioPackets = 12
}

private extension Data {
    nonisolated mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
#endif
