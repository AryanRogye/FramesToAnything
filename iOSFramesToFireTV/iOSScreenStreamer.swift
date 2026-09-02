//
//  iOSScreenStreamer.swift
//  iOSFramesToFireTV
//
//  Created by Aryan Rogye on 7/25/26.
//

import CommonCrypto
import CoreImage
import CoreMedia
import CryptoKit
import ImageIO
import Network
import ReplayKit
import Security
import SnapCore

protocol SampleBufferTransport: AnyObject {
    func send(
        _ sampleBuffer: CMSampleBuffer,
        type: RPSampleBufferType
    )
}

struct FireTVDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    fileprivate let endpoint: NWEndpoint
    let receiverID: String?
    let isRemembered: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isRemembered == rhs.isRemembered
    }
}

enum FireTVConnectionState: Sendable, Equatable {
    case searching
    case connecting(String)
    case authenticating
    case connected(String)
    case failed(String)
    case disconnected

    var message: String {
        switch self {
        case .searching:
            "Looking for Fire TV receivers…"
        case .connecting(let name):
            "Connecting to \(name)…"
        case .authenticating:
            "Checking the pairing code…"
        case .connected(let name):
            "Securely connected to \(name)"
        case .failed(let reason):
            reason
        case .disconnected:
            "Not connected"
        }
    }
}

nonisolated private final class PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer

    init(_ value: CVPixelBuffer) {
        self.value = value
    }
}

/// Discovers the Fire TV app, authenticates with its displayed code, and sends
/// throttled JPEG frames through an AES-GCM encrypted TCP session.
nonisolated final class Transport: SampleBufferTransport, @unchecked Sendable {
    var onDevicesChanged: (@MainActor @Sendable ([FireTVDevice]) -> Void)?
    var onStateChanged: (@MainActor @Sendable (FireTVConnectionState) -> Void)?

    private let networkQueue = DispatchQueue(label: "com.aryanrogye.firetv.network")
    private let encodingQueue = DispatchQueue(label: "com.aryanrogye.firetv.encoding")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let keyLock = NSLock()

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var pairingCode = ""
    private var serverChallenge: Data?
    private var clientChallenge: Data?
    private var handshakeKey: SymmetricKey?
    private var streamingKey: SymmetricKey?
    private var frameSendInFlight = false
    private var connectedName = "Fire TV"
    private var lastEncodedAt = CFAbsoluteTimeGetCurrent()

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
                let devices = results.compactMap { result -> FireTVDevice? in
                    guard case .service(let name, _, _, _) = result.endpoint else {
                        return nil
                    }
                    let receiverID = Self.txtValue("id", from: result)
                    return FireTVDevice(
                        id: receiverID ?? String(describing: result.endpoint),
                        name: name,
                        endpoint: result.endpoint,
                        receiverID: receiverID,
                        isRemembered: receiverID.map(SharedRememberedReceiverStore.contains) ?? false
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self?.publishDevices(devices)
            }
            browser.start(queue: networkQueue)
        }
    }

    func connect(to device: FireTVDevice, code: String) {
        let normalizedCode = code.filter(\.isNumber)
        guard normalizedCode.count == 6 else {
            report(.failed("Enter the six-digit code shown on the Fire TV."))
            return
        }

        networkQueue.async { [weak self] in
            guard let self else { return }
            connection?.cancel()
            clearSession()
            pairingCode = normalizedCode
            connectedName = device.name
            report(.connecting(device.name))

            let connection = NWConnection(to: device.endpoint, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, connection === self.connection else { return }
                switch state {
                case .ready:
                    self.receiveNextChunk()
                case .failed(let error):
                    self.report(.failed("Connection failed: \(error.localizedDescription)"))
                    self.clearSession()
                case .cancelled:
                    self.clearSession()
                default:
                    break
                }
            }
            connection.start(queue: networkQueue)
        }
    }

    func disconnect() {
        networkQueue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.clearSession()
            self?.report(.disconnected)
        }
    }

    func send(_ sampleBuffer: CMSampleBuffer, type: RPSampleBufferType) {
        guard type == .video, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let buffer = PixelBufferBox(imageBuffer)
        encodingQueue.async { [weak self] in
            guard let self, let key = currentStreamingKey() else { return }

            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastEncodedAt >= 1.0 / Self.maximumFramesPerSecond else { return }
            lastEncodedAt = now

            let image = CIImage(cvPixelBuffer: buffer.value)
            guard let jpeg = context.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [
                    kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                        Self.jpegQuality
                ]
            ) else {
                return
            }

            var plaintext = Data([Self.frameVersion])
            var timestamp = UInt64(Date().timeIntervalSince1970 * 1_000).bigEndian
            withUnsafeBytes(of: &timestamp) { plaintext.append(contentsOf: $0) }
            plaintext.append(jpeg)

            guard let sealed = try? AES.GCM.seal(plaintext, using: key),
                  let encrypted = sealed.combined else {
                return
            }
            sendPacket(type: Self.encryptedFramePacket, payload: encrypted, dropIfBusy: true)
        }
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
                report(.failed("Connection ended: \(error.localizedDescription)"))
                clearSession()
                return
            }
            if isComplete {
                report(.disconnected)
                clearSession()
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
            guard length > 0, length <= Self.maximumPacketBytes else {
                report(.failed("The receiver sent an invalid message."))
                connection?.cancel()
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
            report(.failed("The receiver sent an unreadable message."))
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
                  let keyData = Self.deriveKey(code: pairingCode, salt: salt) else {
                report(.failed("The receiver uses an unsupported protocol."))
                return
            }

            let clientChallenge = Self.randomData(count: 32)
            let key = SymmetricKey(data: keyData)
            self.serverChallenge = serverChallenge
            self.clientChallenge = clientChallenge
            self.handshakeKey = key
            report(.authenticating)

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
                report(.failed("The receiver did not complete authentication."))
                return
            }
            let expectedProof = Self.authenticationCode(
                key: key,
                label: "server",
                serverChallenge: serverChallenge,
                clientChallenge: clientChallenge
            )
            guard Self.constantTimeEqual(suppliedProof, expectedProof) else {
                report(.failed("Receiver identity check failed."))
                connection?.cancel()
                return
            }
            setStreamingKey(key)
            report(.connected(connectedName))

        case "auth_failed":
            report(.failed("That pairing code was not accepted."))
            connection?.cancel()

        default:
            break
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        sendPacket(type: Self.jsonPacket, payload: data)
    }

    private func sendPacket(type: UInt8, payload: Data, dropIfBusy: Bool = false) {
        var body = Data([type])
        body.append(payload)
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(body)
        networkQueue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            if dropIfBusy && frameSendInFlight {
                return
            }
            if dropIfBusy {
                frameSendInFlight = true
            }
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                if dropIfBusy {
                    self?.frameSendInFlight = false
                }
                if let error {
                    self?.report(.failed("Send failed: \(error.localizedDescription)"))
                }
            })
        }
    }

    private func clearSession() {
        receiveBuffer.removeAll(keepingCapacity: true)
        pairingCode = ""
        serverChallenge = nil
        clientChallenge = nil
        handshakeKey = nil
        frameSendInFlight = false
        setStreamingKey(nil)
    }

    private func currentStreamingKey() -> SymmetricKey? {
        keyLock.withLock { streamingKey }
    }

    private func setStreamingKey(_ key: SymmetricKey?) {
        keyLock.withLock { streamingKey = key }
    }

    private func report(_ state: FireTVConnectionState) {
        let callback = onStateChanged
        Task { @MainActor in callback?(state) }
    }

    private func publishDevices(_ devices: [FireTVDevice]) {
        let callback = onDevicesChanged
        Task { @MainActor in callback?(devices) }
    }

    private static func txtValue(_ key: String, from result: NWBrowser.Result) -> String? {
        guard case .bonjour(let record) = result.metadata,
              case .string(let value) = record.getEntry(for: key),
              !value.isEmpty else { return nil }
        return value
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

    private static let jsonPacket: UInt8 = 0
    private static let encryptedFramePacket: UInt8 = 1
    private static let frameVersion: UInt8 = 1
    private static let maximumPacketBytes: UInt32 = 64 * 1024
    private static let maximumFramesPerSecond = 12.0
    private static let jpegQuality = 0.62
}

nonisolated enum SharedRememberedReceiverStore {
    static let appGroup = "group.com.aryanrogye.iOSFramesToFireTV"
    private static let prefix = "trusted.receiver."

    static func contains(_ receiverID: String) -> Bool {
        load(receiverID) != nil
    }

    static func load(_ receiverID: String) -> Data? {
        guard let value = UserDefaults(suiteName: appGroup)?
            .string(forKey: prefix + receiverID) else { return nil }
        return Data(base64Encoded: value)
    }
}

final class IOSScreenStreamer {
    private let capture = ScreenCaptureService()
    private let transport: SampleBufferTransport

    init(transport: SampleBufferTransport) {
        self.transport = transport

        capture.onScreenCapture = { [weak self] sampleBuffer, type in
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
            self?.transport.send(sampleBuffer, type: type)
        }

        capture.onError = { error in
            print("ReplayKit capture failed: \(error)")
        }
    }

    func start() {
        capture.startCapture()
    }

    func stop() {
        capture.stopCapture()
    }
}
