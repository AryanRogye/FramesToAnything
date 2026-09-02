#if os(macOS)
import AppKit
import ApplicationServices
import AudioToolbox
import CommonCrypto
import CoreMedia
import CryptoKit
import Foundation
import Network
import OSLog
import Security
import SnapCore
import IOKit.hidsystem

nonisolated private let macTransportLogger = Logger(
    subsystem: "com.aryanrogye.macOSFramesToFireTV",
    category: "MediaTransport"
)

struct MacFireTVDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let receiverID: String?

    var isRemembered: Bool {
        receiverID.map(TrustedReceiverStore.contains) ?? false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

enum MacFireTVConnectionState: Sendable, Equatable {
    case searching
    case waitingForReceiver
    case connecting(String)
    case authenticating(Bool)
    case connected(String)
    case failed(String)
    case disconnected

    var message: String {
        switch self {
        case .searching: "Searching for Fire TV receivers…"
        case .waitingForReceiver: "Waiting for the Fire TV to connect…"
        case .connecting(let name): "Connecting to \(name)…"
        case .authenticating(let remembered):
            remembered ? "Recognizing this receiver…" : "Checking the pairing code…"
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
    var onAdaptiveQualityChanged: (@MainActor @Sendable (MacStreamQuality, Int) -> Void)?

    private let networkQueue = DispatchQueue(
        label: "com.aryanrogye.firetv.mac.network",
        qos: .userInteractive
    )
    private let keyLock = NSLock()
    private let frameAdmissionLock = NSLock()
    private let mediaEncoder: LiveMediaEncoder
    private let cinemaAACEncoder = CinemaAACEncoder()

    init() {
        let encoder = LiveMediaEncoder(
            configuration: .init(
                framesPerSecond: 60,
                averageBitRate: 10_000_000,
                keyFrameInterval: 30
            )
        )
        mediaEncoder = encoder
        encoder.onPacket = { [weak self] packet in
            if packet.kind == .videoFrame {
                self?.completeVideoFrame()
            }
            self?.sendMedia(packet)
        }
        encoder.onError = { [weak self] message in
            self?.resetVideoFrameAdmission()
            self?.networkQueue.async { [weak self] in self?.fail(message) }
        }
    }

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pairingCode = ""
    private var connectedName = "Fire TV"
    private var receiverID: String?
    private var rememberedSecret: Data?
    private var usedRememberedSecret = false
    private var serverChallenge: Data?
    private var clientChallenge: Data?
    private var handshakeKey: SymmetricKey?
    private var streamingKey: SymmetricKey?
    private var usesAACAudio = false
    private var writeInFlight = false
    private var pendingPackets: [QueuedPacket] = []
    private var waitingForCleanVideoFrame = false
    private var receiverFeatures = Set<String>()
    private var qualityLadder: [CinemaQualityLevel] = [.init(.fullHD, 10_000_000)]
    private var qualityLevelIndex = 0
    private var lowBufferReports = 0
    private var healthySince: ContinuousClock.Instant?
    private var lastQualityChange = ContinuousClock.now
    private var lastUnderruns = 0
    private var lastRecoveries = 0
    private var lastRemoteMediaCommand = ContinuousClock.now - .seconds(1)
    private var encoderFramesInFlight = 0

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
                    let receiverID = Self.txtValue("id", from: result)
                        ?? TrustedReceiverStore.receiverID(forServiceName: name)
                    return MacFireTVDevice(
                        id: receiverID ?? String(describing: result.endpoint),
                        name: name,
                        endpoint: result.endpoint,
                        receiverID: receiverID
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self?.publish(devices)
            }
            browser.start(queue: networkQueue)
        }
    }

    func connect(to device: MacFireTVDevice, code: String) {
        waitForReceiver(device: device, code: code)
    }

    func connectDirect(host: String, code: String) {
        let normalizedCode = code.filter(\.isNumber)
        guard normalizedCode.count == 6 else {
            report(.failed("Enter the six-digit code shown on the Fire TV."))
            return
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: 49_218)!
        )
        networkQueue.async { [weak self] in
            guard let self else { return }
            connection?.cancel()
            listener?.cancel()
            listener = nil
            clearSession()
            mediaEncoder.restart()
            pairingCode = normalizedCode
            connectedName = "Fire TV at \(host)"

            let parameters = NWParameters.tcp
            if let tcpOptions = parameters.defaultProtocolStack.transportProtocol
                as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            self.connection = connection
            report(.connecting(connectedName))
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .ready:
                    self.receiveNextChunk(from: connection)
                case .failed(let error):
                    self.fail("Connection failed: \(error.localizedDescription)")
                case .cancelled:
                    self.report(.disconnected)
                default:
                    break
                }
            }
            connection.start(queue: networkQueue)
        }
    }

    /// Advertises a short-lived pairing listener. The Fire TV initiates the
    /// TCP connection, while the existing authenticated media protocol remains
    /// unchanged once the socket is accepted.
    func waitForFireTV(code: String) {
        waitForReceiver(device: nil, code: code)
    }

    private func waitForReceiver(device: MacFireTVDevice?, code: String) {
        let normalizedCode = code.filter(\.isNumber)
        let savedSecret = device?.receiverID.flatMap(TrustedReceiverStore.load)
        guard savedSecret != nil || normalizedCode.count == 6 else {
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
            connectedName = device?.name ?? "Receiver"
            receiverID = device?.receiverID
            rememberedSecret = savedSecret
            usedRememberedSecret = false

            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                if let tcpOptions = parameters.defaultProtocolStack.transportProtocol
                    as? NWProtocolTCP.Options {
                    tcpOptions.noDelay = true
                }
                let listener = try NWListener(using: parameters)
                var serviceTXT = NWTXTRecord([
                    "senderID": Self.senderID,
                ])
                if let receiverID = device?.receiverID {
                    serviceTXT["target"] = receiverID
                }
                listener.service = .init(
                    name: Host.current().localizedName ?? "Mac",
                    type: "_framesmac._tcp",
                    txtRecord: serviceTXT
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
                    self.report(.connecting(self.connectedName))
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        guard let self, let connection, connection === self.connection else { return }
                        switch state {
                        case .ready:
                            self.receiveNextChunk(from: connection)
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

    func forgetSavedConnection(to device: MacFireTVDevice) {
        if let receiverID = device.receiverID {
            TrustedReceiverStore.delete(receiverID)
        }
        disconnect()
    }

    func sendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard currentStreamingKey() != nil, admitVideoFrame() else { return }
        mediaEncoder.encodeVideo(sampleBuffer)
    }

    func sendVideo(_ imageBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard currentStreamingKey() != nil, admitVideoFrame() else { return }
        mediaEncoder.encodeVideo(imageBuffer, timestamp: timestamp)
    }

    func configureVideo(maximumQuality: MacStreamQuality) {
        networkQueue.async { [weak self] in
            guard let self else { return }
            qualityLadder = CinemaQualityLevel.ladder(maximum: maximumQuality)
            qualityLevelIndex = 0
            lowBufferReports = 0
            healthySince = nil
            applyCurrentQuality(force: true)
        }
    }

    func sendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard currentStreamingKey() != nil else { return }
        mediaEncoder.encodeAudio(sampleBuffer)
    }

    private func receiveNextChunk(from connection: NWConnection) {
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
                  serverChallenge.count == 32 else {
                fail("The receiver uses an unsupported authentication protocol.")
                return
            }
            let clientChallenge = Self.randomData(count: 32)
            receiverFeatures = Set(object["features"] as? [String] ?? [])
            let helloReceiverID = object["receiverID"] as? String
            if let expectedID = receiverID,
               let helloReceiverID,
               expectedID != helloReceiverID {
                rejectUnexpectedReceiver()
                return
            }
            receiverID = helloReceiverID ?? receiverID
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
            listener?.cancel()
            listener = nil
            setUsesAACAudio(receiverFeatures.contains(Self.aacFeature))
            setStreamingKey(key)
            report(.connected(connectedName))

        case "auth_failed":
            if usedRememberedSecret, let receiverID {
                TrustedReceiverStore.delete(receiverID)
                fail("This receiver no longer remembers your Mac. Enter its current code once to pair again.")
            } else {
                fail("That pairing code was not accepted. The receiver has generated a new code.")
            }
        case "request_keyframe":
            guard currentStreamingKey() != nil else { return }
            macTransportLogger.info("Receiver requested a clean H.264 keyframe")
            mediaEncoder.stop()
            mediaEncoder.restart()

        case "receiver_report":
            guard currentStreamingKey() != nil else { return }
            handleReceiverReport(object)

        case "remote_media_command":
            guard currentStreamingKey() != nil,
                  receiverFeatures.contains(Self.remoteMediaControlsFeature),
                  object["command"] as? String == "toggle_play_pause" else { return }
            let now = ContinuousClock.now
            guard lastRemoteMediaCommand.duration(to: now) >= .milliseconds(200) else { return }
            lastRemoteMediaCommand = now
            MacMediaKeyController.togglePlayPause()

        default:
            break
        }
    }

    private func handleReceiverReport(_ object: [String: Any]) {
        guard receiverFeatures.contains(Self.receiverReportsFeature) else { return }
        let videoBuffer = object["videoBufferMs"] as? Int ?? 0
        let audioBuffer = object["audioBufferMs"] as? Int ?? 0
        let decoderBacklog = object["decoderBacklogMs"] as? Int ?? 0
        let underruns = object["underruns"] as? Int ?? lastUnderruns
        let recoveries = object["recoveries"] as? Int ?? lastRecoveries
        let effectiveBuffer = min(videoBuffer, audioBuffer)
        let now = ContinuousClock.now

        if effectiveBuffer < 200 {
            stepQualityDown(now: now)
            lowBufferReports = 0
            healthySince = nil
        } else if effectiveBuffer < 450 || decoderBacklog > 250 {
            lowBufferReports += 1
            healthySince = nil
            if lowBufferReports >= 2 {
                stepQualityDown(now: now)
                lowBufferReports = 0
            }
        } else {
            lowBufferReports = 0
            let remainedHealthy = effectiveBuffer >= 650 && decoderBacklog < 100 &&
                underruns == lastUnderruns && recoveries == lastRecoveries
            if remainedHealthy {
                healthySince = healthySince ?? now
                if let healthySince,
                   healthySince.duration(to: now) >= .seconds(20) {
                    stepQualityUp(now: now)
                    self.healthySince = nil
                }
            } else {
                healthySince = nil
            }
        }
        lastUnderruns = underruns
        lastRecoveries = recoveries
    }

    private func stepQualityDown(now: ContinuousClock.Instant) {
        guard lastQualityChange.duration(to: now) >= .seconds(2),
              qualityLevelIndex + 1 < qualityLadder.count else { return }
        qualityLevelIndex += 1
        lastQualityChange = now
        applyCurrentQuality()
    }

    private func stepQualityUp(now: ContinuousClock.Instant) {
        guard lastQualityChange.duration(to: now) >= .seconds(20),
              qualityLevelIndex > 0 else { return }
        qualityLevelIndex -= 1
        lastQualityChange = now
        applyCurrentQuality()
    }

    private func applyCurrentQuality(force: Bool = false) {
        guard qualityLadder.indices.contains(qualityLevelIndex) else { return }
        let level = qualityLadder[qualityLevelIndex]
        mediaEncoder.updateConfiguration(
            .init(
                framesPerSecond: 60,
                averageBitRate: level.averageBitRate,
                keyFrameInterval: 30
            )
        )
        let callback = onAdaptiveQualityChanged
        Task { @MainActor in callback?(level.quality, level.averageBitRate) }
        if force { lastQualityChange = .now }
    }

    private func sendMedia(_ packet: LiveMediaPacket) {
        guard let key = currentStreamingKey() else { return }
        let outgoingPackets: [LiveMediaPacket]
        if currentUsesAACAudio() {
            outgoingPackets = cinemaAACEncoder.transcode(packet) ?? [packet]
        } else {
            outgoingPackets = [packet]
        }

        for outgoingPacket in outgoingPackets {
            encryptAndSend(outgoingPacket, using: key)
        }
    }

    private func encryptAndSend(_ packet: LiveMediaPacket, using key: SymmetricKey) {
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
                if pendingPackets.lazy.filter({ $0.kind == .video }).count >= Self.maximumPendingVideoPackets ||
                    pendingPackets.reduce(0, { $0 + $1.data.count }) + packet.count > Self.maximumPendingBytes {
                    pendingPackets.removeAll { $0.kind == .video }
                    waitingForCleanVideoFrame = true
                    mediaEncoder.stop()
                    mediaEncoder.restart()
                    stepQualityDown(now: .now)
                    return
                }
                pendingPackets.append(
                    .init(data: packet, kind: kind, isKeyFrame: isKeyFrame)
                )
            case .audio:
                if pendingPackets.lazy.filter({ $0.kind == .audio }).count >= Self.maximumPendingAudioPackets {
                    pendingPackets.removeAll { $0.kind == .audio || $0.kind == .video }
                    waitingForCleanVideoFrame = true
                    mediaEncoder.stop()
                    mediaEncoder.restart()
                    stepQualityDown(now: .now)
                    return
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
        connection.send(content: packet.data, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, connection === self.connection else { return }
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

    private func rejectUnexpectedReceiver() {
        let unexpectedConnection = connection
        connection = nil
        unexpectedConnection?.cancel()
        clearHandshakeState()
        report(.waitingForReceiver)
    }

    private func clearSession() {
        clearHandshakeState()
        pairingCode = ""
        receiverID = nil
        rememberedSecret = nil
        usedRememberedSecret = false
    }

    private func clearHandshakeState() {
        receiveBuffer.removeAll(keepingCapacity: true)
        serverChallenge = nil
        clientChallenge = nil
        handshakeKey = nil
        writeInFlight = false
        pendingPackets.removeAll(keepingCapacity: true)
        waitingForCleanVideoFrame = false
        receiverFeatures.removeAll(keepingCapacity: true)
        resetVideoFrameAdmission()
        setUsesAACAudio(false)
        cinemaAACEncoder.reset()
        setStreamingKey(nil)
    }

    private func currentStreamingKey() -> SymmetricKey? {
        keyLock.withLock { streamingKey }
    }

    private func setStreamingKey(_ key: SymmetricKey?) {
        keyLock.withLock { streamingKey = key }
    }

    private func currentUsesAACAudio() -> Bool {
        keyLock.withLock { usesAACAudio }
    }

    private func setUsesAACAudio(_ enabled: Bool) {
        keyLock.withLock { usesAACAudio = enabled }
    }

    private func admitVideoFrame() -> Bool {
        frameAdmissionLock.withLock {
            guard encoderFramesInFlight < Self.maximumEncoderFramesInFlight else {
                return false
            }
            encoderFramesInFlight += 1
            return true
        }
    }

    private func completeVideoFrame() {
        frameAdmissionLock.withLock {
            encoderFramesInFlight = max(0, encoderFramesInFlight - 1)
        }
    }

    private func resetVideoFrameAdmission() {
        frameAdmissionLock.withLock { encoderFramesInFlight = 0 }
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

    private static let senderID: String = {
        let key = "discovery.senderID"
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
    private static let maximumPendingAudioPackets = 100
    private static let maximumPendingVideoPackets = 90
    private static let maximumPendingBytes = 48 * 1024 * 1024
    private static let maximumEncoderFramesInFlight = 6
    private static let receiverReportsFeature = "receiver-report-v1"
    private static let aacFeature = "aac-lc-v1"
    private static let remoteMediaControlsFeature = "remote-media-controls-v1"
    private static let cinemaFeatures: Set<String> = [
        "cinema-buffer-v1",
        receiverReportsFeature,
        "keyframe-request-v1",
        aacFeature,
        remoteMediaControlsFeature,
    ]
}

nonisolated private enum MacMediaKeyController {
    static func togglePlayPause() {
        DispatchQueue.main.async {
            if !AXIsProcessTrusted() {
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            }
            postPlayPause(state: 0xA)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(35)) {
                postPlayPause(state: 0xB)
            }
        }
    }

    private static func postPlayPause(state: Int32) {
        let keyCode = Int32(NX_KEYTYPE_PLAY)
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int((keyCode << 16) | (state << 8)),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}

private struct CinemaQualityLevel: Equatable {
    let quality: MacStreamQuality
    let averageBitRate: Int

    init(_ quality: MacStreamQuality, _ averageBitRate: Int) {
        self.quality = quality
        self.averageBitRate = averageBitRate
    }

    static func ladder(maximum: MacStreamQuality) -> [Self] {
        let all: [Self] = [
            .init(.ultraHD, 32_000_000), .init(.ultraHD, 26_000_000),
            .init(.ultraHD, 20_000_000), .init(.quadHD, 18_000_000),
            .init(.quadHD, 14_000_000), .init(.quadHD, 11_000_000),
            .init(.fullHD, 10_000_000), .init(.fullHD, 8_000_000),
            .init(.fullHD, 6_000_000), .init(.hd, 5_000_000),
            .init(.hd, 4_000_000), .init(.hd, 3_000_000),
        ]
        guard let start = all.firstIndex(where: { $0.quality == maximum }) else {
            return Array(all.suffix(6))
        }
        return Array(all[start...])
    }
}

/// Converts SnapCore's normalized PCM packets into raw AAC-LC access units.
/// Returning `nil` preserves the existing PCM packet unchanged.
nonisolated private final class CinemaAACEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AudioConverterRef?
    private var sampleRate = 0
    private var channels = 0
    private var bytesPerFrame = 0
    private var maximumPacketSize: UInt32 = 0
    private var bufferedPCM = Data()
    private var nextInputTimestampMilliseconds = 0.0
    private var hasInputTimestamp = false
    private var pendingOutputTimestamps: [UInt64] = []

    deinit {
        reset()
    }

    func reset() {
        lock.withLock { resetLocked() }
    }

    func transcode(_ packet: LiveMediaPacket) -> [LiveMediaPacket]? {
        lock.withLock {
            switch packet.kind {
            case .audioConfiguration:
                return configure(from: packet)
            case .audioFrame:
                return encode(packet)
            case .videoConfiguration, .videoFrame:
                return [packet]
            }
        }
    }

    private func configure(from packet: LiveMediaPacket) -> [LiveMediaPacket]? {
        resetLocked()
        guard packet.payload.count >= 6 else { return nil }
        let bytes = [UInt8](packet.payload)
        let inputSampleRate = Int(bytes[0]) << 24 |
            Int(bytes[1]) << 16 |
            Int(bytes[2]) << 8 |
            Int(bytes[3])
        let inputChannels = Int(bytes[4])
        guard bytes[5] == 1,
              inputSampleRate > 0,
              (1...2).contains(inputChannels),
              let frequencyIndex = Self.frequencyIndex(for: inputSampleRate) else {
            return nil
        }

        var inputDescription = AudioStreamBasicDescription(
            mSampleRate: Double(inputSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(inputChannels * 2),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(inputChannels * 2),
            mChannelsPerFrame: UInt32(inputChannels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var outputDescription = AudioStreamBasicDescription(
            mSampleRate: Double(inputSampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 2, // MPEG-4 Audio Object Type: AAC Low Complexity.
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.framesPerAACPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(inputChannels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFormatGetProperty(
            kAudioFormatProperty_FormatInfo,
            0,
            nil,
            &formatSize,
            &outputDescription
        ) == noErr else { return nil }

        var newConverter: AudioConverterRef?
        guard AudioConverterNew(
            &inputDescription,
            &outputDescription,
            &newConverter
        ) == noErr, let newConverter else { return nil }

        var bitRate: UInt32 = inputChannels == 1 ? 96_000 : 192_000
        guard AudioConverterSetProperty(
            newConverter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitRate
        ) == noErr else {
            AudioConverterDispose(newConverter)
            return nil
        }

        var packetSize = UInt32(MemoryLayout<UInt32>.size)
        var maximumPacketSize: UInt32 = 0
        guard AudioConverterGetProperty(
            newConverter,
            kAudioConverterPropertyMaximumOutputPacketSize,
            &packetSize,
            &maximumPacketSize
        ) == noErr, maximumPacketSize > 0 else {
            AudioConverterDispose(newConverter)
            return nil
        }

        converter = newConverter
        sampleRate = inputSampleRate
        channels = inputChannels
        bytesPerFrame = inputChannels * 2
        self.maximumPacketSize = maximumPacketSize

        let audioSpecificConfiguration = Self.audioSpecificConfiguration(
            frequencyIndex: frequencyIndex,
            channels: inputChannels
        )
        var configuration = Data()
        configuration.appendBigEndian(UInt32(inputSampleRate))
        configuration.append(UInt8(inputChannels))
        configuration.append(2)
        configuration.append(audioSpecificConfiguration)
        return [
            LiveMediaPacket(
                kind: .audioConfiguration,
                timestampMilliseconds: packet.timestampMilliseconds,
                payload: configuration
            ),
        ]
    }

    private func encode(_ packet: LiveMediaPacket) -> [LiveMediaPacket]? {
        guard converter != nil, sampleRate > 0, bytesPerFrame > 0 else { return nil }
        if bufferedPCM.isEmpty {
            nextInputTimestampMilliseconds = Double(packet.timestampMilliseconds)
            hasInputTimestamp = true
        }
        bufferedPCM.append(packet.payload)

        let chunkByteCount = Self.framesPerAACPacket * bytesPerFrame
        var output: [LiveMediaPacket] = []
        while bufferedPCM.count >= chunkByteCount {
            let chunk = bufferedPCM.prefix(chunkByteCount)
            bufferedPCM.removeFirst(chunkByteCount)
            guard hasInputTimestamp else { continue }
            pendingOutputTimestamps.append(UInt64(max(0, nextInputTimestampMilliseconds.rounded())))
            nextInputTimestampMilliseconds +=
                Double(Self.framesPerAACPacket) * 1_000 / Double(sampleRate)

            switch encodeChunk(Data(chunk)) {
            case .success(let data):
                guard !data.isEmpty, !pendingOutputTimestamps.isEmpty else { continue }
                output.append(
                    LiveMediaPacket(
                        kind: .audioFrame,
                        timestampMilliseconds: pendingOutputTimestamps.removeFirst(),
                        payload: data
                    )
                )
            case .needsMoreInput:
                continue
            case .failure:
                let fallbackConfiguration = pcmConfiguration(
                    timestampMilliseconds: packet.timestampMilliseconds
                )
                resetLocked()
                return [fallbackConfiguration, packet]
            }
        }
        return output
    }

    private enum EncodeResult {
        case success(Data)
        case needsMoreInput
        case failure
    }

    private func encodeChunk(_ pcm: Data) -> EncodeResult {
        guard let converter else { return .failure }
        var output = Data(count: Int(maximumPacketSize))
        var outputPacketCount: UInt32 = 1
        var packetDescription = AudioStreamPacketDescription()
        var status: OSStatus = noErr
        var outputByteCount = 0

        pcm.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                guard let inputAddress = inputBytes.baseAddress,
                      let outputAddress = outputBytes.baseAddress else {
                    status = kAudio_ParamError
                    return
                }
                var context = CinemaAACInputContext(
                    data: UnsafeMutableRawPointer(mutating: inputAddress),
                    byteCount: UInt32(pcm.count),
                    packetCount: UInt32(Self.framesPerAACPacket),
                    channels: UInt32(channels),
                    supplied: false
                )
                var outputBuffers = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: maximumPacketSize,
                        mData: outputAddress
                    )
                )
                status = withUnsafeMutablePointer(to: &context) { contextPointer in
                    AudioConverterFillComplexBuffer(
                        converter,
                        cinemaAACInputDataProc,
                        contextPointer,
                        &outputPacketCount,
                        &outputBuffers,
                        &packetDescription
                    )
                }
                outputByteCount = Int(outputBuffers.mBuffers.mDataByteSize)
            }
        }

        guard status == noErr else { return .failure }
        guard outputPacketCount > 0, outputByteCount > 0 else { return .needsMoreInput }
        output.removeSubrange(outputByteCount..<output.count)
        return .success(output)
    }

    private func pcmConfiguration(timestampMilliseconds: UInt64) -> LiveMediaPacket {
        var configuration = Data()
        configuration.appendBigEndian(UInt32(sampleRate))
        configuration.append(UInt8(channels))
        configuration.append(1)
        return LiveMediaPacket(
            kind: .audioConfiguration,
            timestampMilliseconds: timestampMilliseconds,
            payload: configuration
        )
    }

    private func resetLocked() {
        if let converter {
            AudioConverterDispose(converter)
        }
        converter = nil
        sampleRate = 0
        channels = 0
        bytesPerFrame = 0
        maximumPacketSize = 0
        bufferedPCM.removeAll(keepingCapacity: false)
        pendingOutputTimestamps.removeAll(keepingCapacity: false)
        nextInputTimestampMilliseconds = 0
        hasInputTimestamp = false
    }

    private static func frequencyIndex(for sampleRate: Int) -> Int? {
        [
            96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
            22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
        ].firstIndex(of: sampleRate)
    }

    private static func audioSpecificConfiguration(
        frequencyIndex: Int,
        channels: Int
    ) -> Data {
        let objectType = 2
        return Data([
            UInt8((objectType << 3) | (frequencyIndex >> 1)),
            UInt8(((frequencyIndex & 1) << 7) | (channels << 3)),
        ])
    }

    private static let framesPerAACPacket = 1_024
}

nonisolated private struct CinemaAACInputContext {
    var data: UnsafeMutableRawPointer
    var byteCount: UInt32
    var packetCount: UInt32
    var channels: UInt32
    var supplied: Bool
}

nonisolated private let cinemaAACInputDataProc: AudioConverterComplexInputDataProc = {
    _, ioNumberDataPackets, ioData, _, userData in
    guard let userData else { return kAudio_ParamError }
    let context = userData.assumingMemoryBound(to: CinemaAACInputContext.self)
    guard !context.pointee.supplied else {
        ioNumberDataPackets.pointee = 0
        return noErr
    }
    ioNumberDataPackets.pointee = context.pointee.packetCount
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mNumberChannels = context.pointee.channels
    ioData.pointee.mBuffers.mDataByteSize = context.pointee.byteCount
    ioData.pointee.mBuffers.mData = context.pointee.data
    context.pointee.supplied = true
    return noErr
}

private enum TrustedReceiverStore {
    nonisolated private static let service = "com.aryanrogye.macOSFramesToFireTV.remembered-receivers"
    nonisolated private static let serviceNameMapKey = "discovery.rememberedReceiverIDs"
    nonisolated private static let fallbackSecretPrefix = "discovery.rememberedReceiverSecret."

    nonisolated static func contains(_ receiverID: String) -> Bool {
        load(receiverID) != nil
    }

    nonisolated static func load(_ receiverID: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: receiverID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return data
        }
        guard let value = UserDefaults.standard.string(
            forKey: fallbackSecretPrefix + receiverID
        ) else { return nil }
        return Data(base64Encoded: value)
    }

    nonisolated static func save(_ secret: Data, for receiverID: String) {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: receiverID,
        ]
        let attributes = [kSecValueData as String: secret]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        let saveStatus: OSStatus
        if updateStatus == errSecItemNotFound {
            var item = lookup
            item[kSecValueData as String] = secret
            saveStatus = SecItemAdd(item as CFDictionary, nil)
        } else {
            saveStatus = updateStatus
        }
        if saveStatus == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackSecretPrefix + receiverID)
        } else {
            UserDefaults.standard.set(
                secret.base64EncodedString(),
                forKey: fallbackSecretPrefix + receiverID
            )
        }
    }

    nonisolated static func associate(receiverID: String, withServiceName serviceName: String) {
        var mappings = UserDefaults.standard.dictionary(forKey: serviceNameMapKey) as? [String: String]
            ?? [:]
        mappings[serviceName] = receiverID
        UserDefaults.standard.set(mappings, forKey: serviceNameMapKey)
    }

    nonisolated static func receiverID(forServiceName serviceName: String) -> String? {
        let mappings = UserDefaults.standard.dictionary(forKey: serviceNameMapKey) as? [String: String]
        return mappings?[serviceName]
    }

    nonisolated static func delete(_ receiverID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: receiverID,
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackSecretPrefix + receiverID)
        if var mappings = UserDefaults.standard.dictionary(forKey: serviceNameMapKey)
            as? [String: String] {
            mappings = mappings.filter { $0.value != receiverID }
            UserDefaults.standard.set(mappings, forKey: serviceNameMapKey)
        }
    }
}

private extension Data {
    nonisolated mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
#endif
