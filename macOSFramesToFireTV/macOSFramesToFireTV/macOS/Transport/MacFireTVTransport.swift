#if os(macOS)
import CoreMedia
import CryptoKit
import Foundation
import Network
import OSLog
import SnapCore

nonisolated let macTransportLogger = Logger(
    subsystem: "com.aryanrogye.macOSFramesToFireTV",
    category: "MediaTransport"
)

/// Authenticated, encrypted, freshness-first media transport shared by the
/// macOS capture callbacks.
nonisolated final class MacFireTVTransport: @unchecked Sendable {
    var onDevicesChanged: (@MainActor @Sendable ([MacFireTVDevice]) -> Void)?
    var onStateChanged: (@MainActor @Sendable (MacFireTVConnectionState) -> Void)?
    var onAdaptiveQualityChanged: (@MainActor @Sendable (MacStreamQuality, Int) -> Void)?

    let networkQueue = DispatchQueue(
        label: "com.aryanrogye.firetv.mac.network",
        qos: .userInteractive
    )
    let keyLock = NSLock()
    let frameAdmissionLock = NSLock()
    let mediaEncoder: LiveMediaEncoder
    let cinemaAACEncoder = CinemaAACEncoder()

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

    var browser: NWBrowser?
    var listener: NWListener?
    var connection: NWConnection?
    var receiveBuffer = Data()
    var pairingCode = ""
    var connectedName = "Fire TV"
    var receiverID: String?
    var rememberedSecret: Data?
    var usedRememberedSecret = false
    var serverChallenge: Data?
    var lastControlSequence: UInt64 = 0
    var clientChallenge: Data?
    var handshakeKey: SymmetricKey?
    var streamingKey: SymmetricKey?
    var usesAACAudio = false
    var writeInFlight = false
    var pendingPackets: [QueuedPacket] = []
    var waitingForCleanVideoFrame = false
    var receiverFeatures = Set<String>()
    var qualityLadder: [CinemaQualityLevel] = [.init(.fullHD, 10_000_000)]
    var qualityLevelIndex = 0
    var lowBufferReports = 0
    var healthySince: ContinuousClock.Instant?
    var lastQualityChange = ContinuousClock.now
    var lastUnderruns = 0
    var lastRecoveries = 0
    var lastRemoteMediaCommand = ContinuousClock.now - .seconds(1)
    var encoderFramesInFlight = 0

    // Shared with this type’s extensions; session mutations remain on networkQueue.

    func fail(_ message: String) {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        clearSession()
        report(.failed(message))
    }

    func rejectUnexpectedReceiver() {
        let unexpectedConnection = connection
        connection = nil
        unexpectedConnection?.cancel()
        clearHandshakeState()
        report(.waitingForReceiver)
    }

    func clearSession() {
        clearHandshakeState()
        pairingCode = ""
        receiverID = nil
        rememberedSecret = nil
        usedRememberedSecret = false
    }

    func clearHandshakeState() {
        lastControlSequence = 0
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

    func currentStreamingKey() -> SymmetricKey? {
        keyLock.withLock { streamingKey }
    }

    func setStreamingKey(_ key: SymmetricKey?) {
        keyLock.withLock { streamingKey = key }
    }

    func currentUsesAACAudio() -> Bool {
        keyLock.withLock { usesAACAudio }
    }

    func setUsesAACAudio(_ enabled: Bool) {
        keyLock.withLock { usesAACAudio = enabled }
    }

    func admitVideoFrame() -> Bool {
        frameAdmissionLock.withLock {
            guard encoderFramesInFlight < Self.maximumEncoderFramesInFlight else {
                return false
            }
            encoderFramesInFlight += 1
            return true
        }
    }

    func completeVideoFrame() {
        frameAdmissionLock.withLock {
            encoderFramesInFlight = max(0, encoderFramesInFlight - 1)
        }
    }

    func resetVideoFrameAdmission() {
        frameAdmissionLock.withLock { encoderFramesInFlight = 0 }
    }

    func report(_ state: MacFireTVConnectionState) {
        let callback = onStateChanged
        Task { @MainActor in callback?(state) }
    }

    func publish(_ devices: [MacFireTVDevice]) {
        let callback = onDevicesChanged
        Task { @MainActor in callback?(devices) }
    }

    struct QueuedPacket {
        enum Kind: Equatable { case control, audio, video, caption }
        let data: Data
        let kind: Kind
        let isKeyFrame: Bool
    }

    static let jsonPacket: UInt8 = 0
    static let encryptedMediaPacket: UInt8 = 2
    static let mediaVersion: UInt8 = 2
    static let maximumJSONPacketBytes: UInt32 = 64 * 1024
    static let maximumPendingAudioPackets = 100
    static let maximumPendingVideoPackets = 90
    static let maximumPendingBytes = 48 * 1024 * 1024
    static let maximumEncoderFramesInFlight = 6
    static let receiverReportsFeature = "receiver-report-v1"
    static let aacFeature = "aac-lc-v1"
    static let remoteMediaControlsFeature = "remote-media-controls-v1"
    static let cinemaFeatures: Set<String> = [
        ReceiverControlAuthentication.feature,
        "cinema-buffer-v1",
        "live-captions-v1",
        receiverReportsFeature,
        "keyframe-request-v1",
        aacFeature,
        remoteMediaControlsFeature,
    ]
}
#endif
