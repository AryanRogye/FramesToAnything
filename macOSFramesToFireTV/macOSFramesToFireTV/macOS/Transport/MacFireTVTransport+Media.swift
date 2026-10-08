#if os(macOS)
import OSLog
import CoreMedia
import CryptoKit
import Foundation
import Network
import SnapCore

/// Encoded video/audio/caption packets, encryption, and the bounded network write queue.
/// This extension uses the same transport state and queues; it creates no new pipeline.
extension MacFireTVTransport {
    nonisolated func sendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard currentStreamingKey() != nil, admitVideoFrame() else { return }
        mediaEncoder.encodeVideo(sampleBuffer)
    }

    nonisolated func sendVideo(_ imageBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard currentStreamingKey() != nil, admitVideoFrame() else { return }
        mediaEncoder.encodeVideo(imageBuffer, timestamp: timestamp)
    }

    nonisolated func sendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard currentStreamingKey() != nil else { return }
        mediaEncoder.encodeAudio(sampleBuffer)
    }

    nonisolated func sendMedia(_ packet: LiveMediaPacket) {
        guard let (key, generation) = mediaSession() else { return }
        let outgoingPackets: [LiveMediaPacket]
        if currentUsesAACAudio() {
            outgoingPackets = cinemaAACEncoder.transcode(packet) ?? [packet]
        } else {
            outgoingPackets = [packet]
        }

        for outgoingPacket in outgoingPackets {
            encryptAndSend(outgoingPacket, using: key, generation: generation)
        }
    }

    nonisolated func encryptAndSend(_ packet: LiveMediaPacket, using key: SymmetricKey, generation: UInt64) {
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
            isKeyFrame: packet.isKeyFrame,
            generation: generation
        )
    }

    /// At most one tiny caption waits behind media. No encoder interaction.
    nonisolated func sendCaption(_ cue: LiveCaptionCue) {
        networkQueue.async { [weak self] in
            guard let self, let connection,
                  receiverFeatures.contains("live-captions-v1"),
                  let key = currentStreamingKey(),
                  let payload = try? JSONEncoder().encode(cue), payload.count <= 2048 else { return }
            var plaintext = Data([Self.mediaVersion, 5])
            plaintext.appendBigEndian(cue.startMs)
            plaintext.append(0)
            plaintext.append(payload)
            guard let encrypted = try? AES.GCM.seal(plaintext, using: key).combined else { return }
            var body = Data([Self.encryptedMediaPacket])
            body.append(encrypted)
            var packet = Data()
            packet.appendBigEndian(UInt32(body.count))
            packet.append(body)
            enqueue(packet, kind: .caption, isKeyFrame: false, connection: connection)
        }
    }

    nonisolated func sendJSON(_ object: [String: Any]) {
        guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        sendPacket(type: Self.jsonPacket, payload: payload, kind: .control)
    }

    nonisolated func sendPacket(
        type: UInt8,
        payload: Data,
        kind: QueuedPacket.Kind,
        isKeyFrame: Bool = false,
        generation: UInt64? = nil
    ) {
        var body = Data([type])
        body.append(payload)
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        packet.append(body)
        let expectedGeneration = generation ?? currentMediaGeneration()
        networkQueue.async { [weak self] in
            guard let self, let connection, currentMediaGeneration() == expectedGeneration else { return }
            enqueue(packet, kind: kind, isKeyFrame: isKeyFrame, connection: connection)
        }
    }

    nonisolated func enqueue(
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
                    macTransportLogger.warning("Video send queue overflow packets=\(self.pendingPackets.count) incomingBytes=\(packet.count)")
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
                    macTransportLogger.warning("Audio send queue overflow packets=\(self.pendingPackets.count)")
                    pendingPackets.removeAll { $0.kind == .audio || $0.kind == .video }
                    waitingForCleanVideoFrame = true
                    mediaEncoder.stop()
                    mediaEncoder.restart()
                    stepQualityDown(now: .now)
                    return
                }
                pendingPackets.append(.init(data: packet, kind: kind, isKeyFrame: false))
            case .caption:
                pendingPackets.removeAll { $0.kind == .caption }
                pendingPackets.append(.init(data: packet, kind: kind, isKeyFrame: false))
            case .control:
                pendingPackets.append(.init(data: packet, kind: kind, isKeyFrame: false))
            }
            return
        }
        write(.init(data: packet, kind: kind, isKeyFrame: isKeyFrame), using: connection)
    }

    nonisolated func write(_ packet: QueuedPacket, using connection: NWConnection) {
        writeInFlight = true
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, connection === self.connection else { return }
            fail("Network write stalled. Ready to reconnect.")
        }
        writeDeadline = deadline
        networkQueue.asyncAfter(deadline: .now() + 12, execute: deadline)
        connection.send(content: packet.data, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, connection === self.connection else { return }
            writeDeadline?.cancel()
            writeDeadline = nil
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

}
#endif
