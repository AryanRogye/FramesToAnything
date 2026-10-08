#if os(macOS)
import AudioToolbox
import CoreMedia
import Foundation
import SnapCore

/// Converts SnapCore's normalized PCM packets into raw AAC-LC access units.
/// Returning `nil` preserves the existing PCM packet unchanged.
nonisolated final class CinemaAACEncoder: @unchecked Sendable {
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
#endif
