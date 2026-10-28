import AVFoundation
import CommonCrypto
import CoreImage
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
    let receiverID: String?
    let pairingCode: String?
    let rememberedSecret: Data?

    static func load() -> BroadcastConfiguration? {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            return nil
        }
        let serviceName = defaults.string(forKey: serviceNameKey)
        let manualHost = defaults.string(forKey: manualHostKey)
        let receiverID = defaults.string(forKey: receiverIDKey)
        let pairingCode = defaults.string(forKey: pairingCodeKey)
            .flatMap { $0.count == 6 ? $0 : nil }
        let rememberedSecret = receiverID.flatMap(BroadcastRememberedReceiverStore.load)
        guard serviceName?.isEmpty == false || manualHost?.isEmpty == false else {
            return nil
        }
        guard rememberedSecret != nil || pairingCode != nil else { return nil }
        return BroadcastConfiguration(
            serviceName: serviceName,
            manualHost: manualHost,
            receiverID: receiverID,
            pairingCode: pairingCode,
            rememberedSecret: rememberedSecret
        )
    }

    private static let appGroup = "group.com.aryanrogye.iOSFramesToFireTV"
    private static let serviceNameKey = "broadcast.serviceName"
    private static let manualHostKey = "broadcast.manualHost"
    private static let pairingCodeKey = "broadcast.pairingCode"
    private static let receiverIDKey = "broadcast.receiverID"
}

/// A self-contained sender owned by the ReplayKit extension process. The host
/// app can be suspended without affecting this connection.
nonisolated final class BroadcastTransport: @unchecked Sendable {
    var onFailure: (@Sendable (String) -> Void)?
    var isPaused = false

    private let configuration: BroadcastConfiguration
    private let networkQueue = DispatchQueue(label: "com.aryanrogye.firetv.broadcast.network")
    private let videoQueue = DispatchQueue(label: "com.aryanrogye.firetv.broadcast.framing", qos: .userInteractive)
    private let videoFrameLock = NSLock()
    private let keyLock = NSLock()
    private let videoFramer = BroadcastVideoFramer()
    private let audioConverter = BroadcastAudioConverter()
    private var videoFramePending = false

    private let mediaEncoder: LiveMediaEncoder

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var discoveryTimeout: DispatchWorkItem?
    private var receiveBuffer = Data()
    private var serverChallenge: Data?
    private var clientChallenge: Data?
    private var handshakeKey: SymmetricKey?
    private var usedRememberedSecret = false
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
                averageBitRate: 6_000_000,
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
        audioConverter.onPacket = { [weak self] packet in
            self?.sendMedia(packet)
        }
        audioConverter.onError = { [weak self] message in
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
            guard let source = CMSampleBufferGetImageBuffer(sampleBuffer),
                  videoFrameLock.withLock({
                      guard !videoFramePending else { return false }
                      videoFramePending = true
                      return true
                  }) else { return }
            let retained = BroadcastPixelBuffer(source)
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let orientation = Self.videoOrientation(from: sampleBuffer)
            videoQueue.async { [weak self] in
                guard let self else { return }
                defer { self.videoFrameLock.withLock { self.videoFramePending = false } }
                guard self.currentStreamingKey() != nil,
                      let framed = self.videoFramer.frame(retained.value, orientation: orientation) else {
                    return
                }
                self.mediaEncoder.encodeVideo(framed, timestamp: timestamp, rotationDegrees: 0)
            }
        case .audioApp:
            // App audio is the sound users expect to hear on the Fire TV.
            audioConverter.encode(sampleBuffer)
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
                if let receiverID = self.configuration.receiverID,
                   let foundID = Self.txtValue("id", from: result) {
                    return receiverID == foundID
                }
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
                  serverChallenge.count == 32 else {
                fail("The Fire TV uses an unsupported authentication protocol.")
                return
            }

            let clientChallenge = Self.randomData(count: 32)
            let helloReceiverID = object["receiverID"] as? String
            if let expectedID = configuration.receiverID,
               let helloReceiverID,
               expectedID != helloReceiverID {
                fail("A different Fire TV answered the broadcast request.")
                return
            }
            let keyData: Data?
            let mode: String
            if let secret = configuration.rememberedSecret {
                keyData = Self.deriveRememberedSessionKey(
                    secret: secret,
                    salt: salt,
                    serverChallenge: serverChallenge,
                    clientChallenge: clientChallenge
                )
                mode = "remembered"
                usedRememberedSecret = true
            } else if let code = configuration.pairingCode {
                keyData = Self.deriveKey(code: code, salt: salt)
                mode = "code"
                usedRememberedSecret = false
            } else {
                keyData = nil
                mode = "code"
            }
            guard let keyData else {
                fail("Open the sender app and pair with this Fire TV again.")
                return
            }
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
                "name": "iPhone or iPad",
                "senderID": BroadcastRememberedReceiverStore.senderID,
                "mode": mode,
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
            if !usedRememberedSecret, let receiverID = configuration.receiverID {
                let secret = Self.deriveTrustSecret(
                    key: key,
                    serverChallenge: serverChallenge,
                    clientChallenge: clientChallenge
                )
                BroadcastRememberedReceiverStore.save(secret, for: receiverID)
            }
            setStreamingKey(key)

        case "auth_failed":
            if usedRememberedSecret, let receiverID = configuration.receiverID {
                BroadcastRememberedReceiverStore.delete(receiverID)
                fail("This Fire TV needs to pair again. Reopen the sender app and enter its current code once.")
            } else {
                fail("The Fire TV rejected the pairing code. Reopen the sender app and enter the new TV code.")
            }

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
                if kind == .audio &&
                    pendingPackets.lazy.filter({ $0.kind == .audio }).count >= Self.maximumPendingAudioPackets {
                    fail("The Wi-Fi connection cannot keep up with audio. Move closer to the Fire TV and start a new broadcast.")
                    return
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
        usedRememberedSecret = false
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

    private static func videoOrientation(
        from sampleBuffer: CMSampleBuffer
    ) -> CGImagePropertyOrientation {
        guard let value = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: value.uint32Value) else {
            return .up
        }
        // ReplayKit's landscape attachment describes the device turn, while
        // CIImage.oriented(_:) applies an image turn. Use the opposite quarter
        // turn so landscape content is upright in the encoded 16:9 frame.
        switch orientation {
        case .left: return .right
        case .right: return .left
        case .leftMirrored: return .rightMirrored
        case .rightMirrored: return .leftMirrored
        default: return orientation
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
    // Roughly three seconds of ReplayKit's typical 48 kHz / 1,024-frame PCM
    // packets. Dropping individual PCM packets produces audible crackles and
    // repeatedly resets the receiver's audio clock.
    private static let maximumPendingAudioPackets = 150
}

nonisolated private final class BroadcastPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

/// The Fire TV renders into a full-screen 16:9 surface. Bake orientation and
/// aspect-fit bars into the encoded frame so portrait video cannot be stretched.
nonisolated private final class BroadcastVideoFramer {
    private static let width = 1280
    private static let height = 720
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let pool: CVPixelBufferPool?

    init() {
        var createdPool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Self.width,
            kCVPixelBufferHeightKey: Self.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
            attributes as CFDictionary,
            &createdPool
        )
        pool = createdPool
    }

    func frame(
        _ source: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else { return nil }

        let upright = CIImage(cvPixelBuffer: source).oriented(orientation)
        let extent = upright.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
        let scale = min(canvas.width / extent.width, canvas.height / extent.height)
        let fitted = upright
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: (canvas.width - extent.width * scale) / 2,
                y: (canvas.height - extent.height * scale) / 2
            ))
        let image = fitted.composited(over: CIImage(color: .black).cropped(to: canvas))
        context.render(image, to: destination, bounds: canvas, colorSpace: colorSpace)
        return destination
    }
}

nonisolated private struct BroadcastAudioSample: @unchecked Sendable {
    let value: CMSampleBuffer
}

/// ReplayKit commonly supplies planar floating-point app audio. Convert from
/// its declared Core Media format instead of interpreting sample bytes by hand.
nonisolated private final class BroadcastAudioConverter: @unchecked Sendable {
    var onPacket: (@Sendable (LiveMediaPacket) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "com.aryanrogye.firetv.broadcast.audio", qos: .userInteractive)
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let retained = BroadcastAudioSample(value: sampleBuffer)
        queue.async { [weak self] in self?.convert(retained.value) }
    }

    private func convert(_ sample: CMSampleBuffer) {
        let frameCount = CMSampleBufferGetNumSamples(sample)
        guard frameCount > 0,
              let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.sampleRate > 0,
              frameCount <= Int(format.sampleRate),
              let input = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            onError?("ReplayKit supplied an unsupported app-audio format.")
            return
        }
        input.frameLength = AVAudioFrameCount(frameCount)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frameCount),
            into: input.mutableAudioBufferList
        ) == noErr else {
            onError?("Could not read ReplayKit app audio.")
            return
        }

        if inputFormat != format {
            let channels = min(format.channelCount, 2)
            guard channels > 0,
                  let pcmFormat = AVAudioFormat(
                      commonFormat: .pcmFormatInt16,
                      sampleRate: format.sampleRate,
                      channels: channels,
                      interleaved: true
                  ),
                  let newConverter = AVAudioConverter(from: format, to: pcmFormat) else {
                onError?("Could not prepare app-audio conversion.")
                return
            }
            newConverter.primeMethod = .none
            converter = newConverter
            inputFormat = format
            outputFormat = pcmFormat

            var configuration = Data()
            var sampleRate = UInt32(format.sampleRate.rounded()).bigEndian
            withUnsafeBytes(of: &sampleRate) { configuration.append(contentsOf: $0) }
            configuration.append(UInt8(channels))
            configuration.append(1) // Interleaved signed 16-bit PCM.
            onPacket?(LiveMediaPacket(
                kind: .audioConfiguration,
                timestampMilliseconds: Self.timestampMilliseconds(for: sample),
                payload: configuration
            ))
        }

        guard let converter, let outputFormat,
              let output = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(frameCount + 64)
              ) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else {
            onError?("Could not convert ReplayKit app audio to PCM.")
            return
        }
        guard output.frameLength > 0 else { return }
        let expectedBytes = Int(output.frameLength) * Int(outputFormat.channelCount) * 2
        let buffer = output.audioBufferList.pointee.mBuffers
        guard expectedBytes > 0,
              output.audioBufferList.pointee.mNumberBuffers == 1,
              Int(buffer.mDataByteSize) >= expectedBytes,
              let bytes = buffer.mData else {
            onError?("Could not convert ReplayKit app audio to PCM.")
            return
        }
        onPacket?(LiveMediaPacket(
            kind: .audioFrame,
            timestampMilliseconds: Self.timestampMilliseconds(for: sample),
            payload: Data(bytes: bytes, count: expectedBytes)
        ))
    }

    private static func timestampMilliseconds(for sample: CMSampleBuffer) -> UInt64 {
        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return UInt64(seconds * 1_000)
    }
}

nonisolated private enum BroadcastRememberedReceiverStore {
    private static let appGroup = "group.com.aryanrogye.iOSFramesToFireTV"
    private static let prefix = "trusted.receiver."

    static var senderID: String {
        guard let defaults = UserDefaults(suiteName: appGroup) else {
            return UUID().uuidString.lowercased()
        }
        let key = "broadcast.senderID"
        if let value = defaults.string(forKey: key) { return value }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }

    static func load(_ receiverID: String) -> Data? {
        guard let value = UserDefaults(suiteName: appGroup)?
            .string(forKey: prefix + receiverID) else { return nil }
        return Data(base64Encoded: value)
    }

    static func save(_ secret: Data, for receiverID: String) {
        UserDefaults(suiteName: appGroup)?.set(
            secret.base64EncodedString(),
            forKey: prefix + receiverID
        )
    }

    static func delete(_ receiverID: String) {
        UserDefaults(suiteName: appGroup)?.removeObject(forKey: prefix + receiverID)
    }
}
