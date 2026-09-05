import AVFoundation
import CoreMedia
import Darwin.Mach
import Observation
import SwiftUI
import UIKit

struct iOSCinemaPlaybackReport: Sendable {
    let videoBufferMilliseconds: Int
    let audioBufferMilliseconds: Int
    let decoderBacklogMilliseconds: Int
    let underruns: Int
    let recoveries: Int
    let lastPresentedTimestampMilliseconds: Int64
}

@Observable
@MainActor
final class iOSMediaPlayer {
    var hasVideo = false
    var lastError: String?
    var onReport: (@MainActor @Sendable (iOSCinemaPlaybackReport) -> Void)?
    var onKeyFrameNeeded: (@MainActor @Sendable (String, Int64) -> Void)?

    private struct PreparedVideo {
        let sampleBuffer: CMSampleBuffer
        let sourceTimestampMilliseconds: Int64
        let isKeyFrame: Bool
    }

    private struct LayerState {
        weak var layer: AVSampleBufferDisplayLayer?
        var pendingSamples: [CMSampleBuffer]
    }

    private static let targetBufferMilliseconds: Int64 = 750
    private static let maximumPendingVideoFrames = 120

    private var videoFormatDescription: CMVideoFormatDescription?
    private var waitingForKeyFrame = true
    private var pendingVideo: [PreparedVideo] = []
    private var groupOfPictures: [PreparedVideo] = []
    private var layerStates: [ObjectIdentifier: LayerState] = [:]

    private let audioEngine = AVAudioEngine()
    private let audioNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var compressedAudioFormat: AVAudioFormat?
    private var audioDecoder: AVAudioConverter?
    private var audioEncoding = 0
    private var audioChannels = 0
    private var audioSampleRate = 0
    private var audioBytesPerFrame = 0
    private var audioScheduledFrames: AVAudioFramePosition = 0
    private var audioCompletedFrames: AVAudioFramePosition = 0
    private var audioFirstTimestampMilliseconds: Int64?
    private var latestAudioTimestampMilliseconds: Int64 = 0

    private var playbackStarted = false
    private var sourcePlaybackOriginMilliseconds: Int64?
    private var firstVideoTimestampMilliseconds: Int64?
    private var latestVideoTimestampMilliseconds: Int64 = 0
    private var lastPresentedTimestampMilliseconds: Int64 = 0
    private var underrunCount = 0
    private var recoveryCount = 0
    private var wasAudioBufferLow = false
    private var reportTimer: Timer?

    @ObservationIgnored
    private let playbackTimebase: CMTimebase

    init() {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        playbackTimebase = timebase!
        audioEngine.attach(audioNode)
    }

    func configureVideo(sps: Data, pps: Data) {
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &videoFormatDescription
                        )
                    }
                }
            }
        }

        guard status == noErr else {
            lastError = "Unable to configure the H.264 decoder (\(status))."
            return
        }

        waitingForKeyFrame = true
        pendingVideo.removeAll(keepingCapacity: true)
        groupOfPictures.removeAll(keepingCapacity: true)
        for state in layerStates.values {
            state.layer?.flushAndRemoveImage()
        }
    }

    func configureAudio(
        sampleRate: Int,
        channels: Int,
        encoding: Int,
        codecConfiguration: Data
    ) {
        guard sampleRate > 0, channels > 0,
              (encoding == 1 || encoding == 2),
              let playbackFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(sampleRate),
                channels: AVAudioChannelCount(channels),
                interleaved: true
              ) else {
            lastError = "Unable to configure PCM audio."
            return
        }

        let requiresPlaybackRecovery = playbackStarted
        if requiresPlaybackRecovery {
            playbackStarted = false
            sourcePlaybackOriginMilliseconds = nil
            CMTimebaseSetRate(playbackTimebase, rate: 0)
            pendingVideo.removeAll(keepingCapacity: true)
            groupOfPictures.removeAll(keepingCapacity: true)
            firstVideoTimestampMilliseconds = nil
            latestVideoTimestampMilliseconds = 0
            waitingForKeyFrame = true
            recoveryCount += 1
            for identifier in layerStates.keys {
                layerStates[identifier]?.pendingSamples.removeAll(keepingCapacity: true)
                layerStates[identifier]?.layer?.flushAndRemoveImage()
            }
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioNode.stop()
        audioScheduledFrames = 0
        audioCompletedFrames = 0
        audioFirstTimestampMilliseconds = nil
        latestAudioTimestampMilliseconds = 0
        audioEngine.disconnectNodeOutput(audioNode)
        audioEngine.connect(audioNode, to: audioEngine.mainMixerNode, format: playbackFormat)
        audioEngine.prepare()

        do {
            try audioEngine.start()
            audioFormat = playbackFormat
            audioEncoding = encoding
            audioChannels = channels
            audioSampleRate = sampleRate
            audioBytesPerFrame = channels * MemoryLayout<Int16>.size

            if encoding == 2 {
                var compressedDescription = AudioStreamBasicDescription(
                    mSampleRate: Double(sampleRate),
                    mFormatID: kAudioFormatMPEG4AAC,
                    mFormatFlags: 2,
                    mBytesPerPacket: 0,
                    mFramesPerPacket: 1_024,
                    mBytesPerFrame: 0,
                    mChannelsPerFrame: UInt32(channels),
                    mBitsPerChannel: 0,
                    mReserved: 0
                )
                var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                guard AudioFormatGetProperty(
                    kAudioFormatProperty_FormatInfo,
                    0,
                    nil,
                    &descriptionSize,
                    &compressedDescription
                ) == noErr,
                      let compressedFormat = AVAudioFormat(
                        streamDescription: &compressedDescription
                      ),
                      let converter = AVAudioConverter(
                        from: compressedFormat,
                        to: playbackFormat
                      ) else {
                    lastError = "Unable to configure AAC audio."
                    return
                }
                converter.magicCookie = codecConfiguration
                compressedAudioFormat = compressedFormat
                audioDecoder = converter
            } else {
                compressedAudioFormat = nil
                audioDecoder = nil
            }
            if requiresPlaybackRecovery {
                onKeyFrameNeeded?("audio_codec_changed", lastPresentedTimestampMilliseconds)
            }
        } catch {
            lastError = "Unable to start audio playback: \(error.localizedDescription)"
        }
    }

    func enqueueVideo(_ annexBData: Data, timestampMilliseconds: Int64, isKeyFrame: Bool) {
        guard let videoFormatDescription else { return }
        guard !waitingForKeyFrame || isKeyFrame else { return }

        if isKeyFrame {
            waitingForKeyFrame = false
            groupOfPictures.removeAll(keepingCapacity: true)
        }

        guard let avccData = convertAnnexBToAVCC(annexBData),
              let sampleBuffer = makeSampleBuffer(
                avccData: avccData,
                timestampMilliseconds: timestampMilliseconds,
                isKeyFrame: isKeyFrame,
                formatDescription: videoFormatDescription
              ) else {
            enterRecovery(reason: "invalid_video_sample")
            return
        }

        let prepared = PreparedVideo(
            sampleBuffer: sampleBuffer,
            sourceTimestampMilliseconds: timestampMilliseconds,
            isKeyFrame: isKeyFrame
        )
        firstVideoTimestampMilliseconds = firstVideoTimestampMilliseconds ?? timestampMilliseconds
        latestVideoTimestampMilliseconds = max(latestVideoTimestampMilliseconds, timestampMilliseconds)

        if !playbackStarted {
            pendingVideo.append(prepared)
            if pendingVideo.count > Self.maximumPendingVideoFrames {
                enterRecovery(reason: "video_buffer_overflow")
                return
            }
            maybeStartPlayback()
            return
        }

        deliver(prepared)
    }

    func enqueueAudio(_ pcmData: Data, timestampMilliseconds: Int64) {
        guard !pcmData.isEmpty else { return }
        if audioEncoding == 2 {
            decodeAAC(pcmData, timestampMilliseconds: timestampMilliseconds)
        } else {
            schedulePCMData(pcmData, timestampMilliseconds: timestampMilliseconds)
        }
    }

    private func schedulePCMData(_ pcmData: Data, timestampMilliseconds: Int64) {
        guard let audioFormat, audioBytesPerFrame > 0 else { return }
        let frameCount = pcmData.count / audioBytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
        pcmData.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(destination, source, min(pcmData.count, Int(buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize)))
        }

        schedulePCMBuffer(buffer, timestampMilliseconds: timestampMilliseconds)
    }

    private func decodeAAC(_ data: Data, timestampMilliseconds: Int64) {
        guard let compressedAudioFormat, let audioDecoder, let audioFormat else { return }
        let compressedBuffer = AVAudioCompressedBuffer(
            format: compressedAudioFormat,
            packetCapacity: 1,
            maximumPacketSize: data.count
        )
        compressedBuffer.packetCount = 1
        compressedBuffer.byteLength = UInt32(data.count)
        data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(compressedBuffer.data, source, data.count)
        }
        compressedBuffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 1_024,
            mDataByteSize: UInt32(data.count)
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: 2_048
        ) else { return }
        var suppliedInput = false
        var conversionError: NSError?
        let status = audioDecoder.convert(to: outputBuffer, error: &conversionError) {
            _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return compressedBuffer
        }
        guard status != .error, conversionError == nil else {
            lastError = "AAC decoding failed: \(conversionError?.localizedDescription ?? "unknown error")"
            return
        }
        guard outputBuffer.frameLength > 0 else { return }
        schedulePCMBuffer(outputBuffer, timestampMilliseconds: timestampMilliseconds)
    }

    private func schedulePCMBuffer(
        _ buffer: AVAudioPCMBuffer,
        timestampMilliseconds: Int64
    ) {
        let frameCount = Int(buffer.frameLength)
        audioFirstTimestampMilliseconds = audioFirstTimestampMilliseconds ?? timestampMilliseconds
        latestAudioTimestampMilliseconds = max(
            latestAudioTimestampMilliseconds,
            timestampMilliseconds + milliseconds(forFrames: frameCount)
        )
        audioScheduledFrames += AVAudioFramePosition(frameCount)

        audioNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.audioCompletedFrames += AVAudioFramePosition(frameCount)
            }
        }
        maybeStartPlayback()
    }

    func register(_ layer: AVSampleBufferDisplayLayer) {
        let identifier = ObjectIdentifier(layer)
        layer.videoGravity = .resizeAspect
        layer.controlTimebase = playbackTimebase
        layerStates[identifier] = LayerState(layer: layer, pendingSamples: [])

        guard playbackStarted else { return }
        for prepared in groupOfPictures {
            guard let retimed = retimedSample(prepared) else { continue }
            layerStates[identifier]?.pendingSamples.append(retimed)
        }
        drainLayer(identifier)
    }

    func unregister(_ layer: AVSampleBufferDisplayLayer) {
        layerStates.removeValue(forKey: ObjectIdentifier(layer))
    }

    func reset() {
        reportTimer?.invalidate()
        reportTimer = nil
        playbackStarted = false
        sourcePlaybackOriginMilliseconds = nil
        CMTimebaseSetRate(playbackTimebase, rate: 0)
        CMTimebaseSetTime(playbackTimebase, time: .zero)
        firstVideoTimestampMilliseconds = nil
        latestVideoTimestampMilliseconds = 0
        lastPresentedTimestampMilliseconds = 0
        waitingForKeyFrame = true
        pendingVideo.removeAll(keepingCapacity: false)
        groupOfPictures.removeAll(keepingCapacity: false)
        videoFormatDescription = nil
        hasVideo = false
        lastError = nil

        audioNode.stop()
        audioEngine.stop()
        audioFormat = nil
        compressedAudioFormat = nil
        audioDecoder = nil
        audioEncoding = 0
        audioChannels = 0
        audioSampleRate = 0
        audioBytesPerFrame = 0
        audioScheduledFrames = 0
        audioCompletedFrames = 0
        audioFirstTimestampMilliseconds = nil
        latestAudioTimestampMilliseconds = 0
        wasAudioBufferLow = false

        for key in layerStates.keys {
            layerStates[key]?.pendingSamples.removeAll(keepingCapacity: false)
            layerStates[key]?.layer?.flushAndRemoveImage()
        }
    }

    private func maybeStartPlayback() {
        guard !playbackStarted,
              let audioOrigin = audioFirstTimestampMilliseconds,
              let firstVideoTimestampMilliseconds else { return }

        let scheduledAudioMilliseconds = milliseconds(forFrames: Int(audioScheduledFrames))
        let videoBufferedMilliseconds = latestVideoTimestampMilliseconds - firstVideoTimestampMilliseconds
        guard scheduledAudioMilliseconds >= Self.targetBufferMilliseconds,
              videoBufferedMilliseconds >= Self.targetBufferMilliseconds else { return }

        let leadTimeSeconds = 0.05
        sourcePlaybackOriginMilliseconds = audioOrigin
        CMTimebaseSetTime(
            playbackTimebase,
            time: CMTime(
                value: audioOrigin - Int64(leadTimeSeconds * 1_000),
                timescale: 1_000
            )
        )
        CMTimebaseSetRate(playbackTimebase, rate: 1)
        playbackStarted = true
        audioNode.play(at: AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadTimeSeconds)))

        let buffered = pendingVideo
        pendingVideo.removeAll(keepingCapacity: true)
        for prepared in buffered {
            deliver(prepared)
        }
        startReportTimer()
    }

    private func deliver(_ prepared: PreparedVideo) {
        if prepared.isKeyFrame {
            groupOfPictures.removeAll(keepingCapacity: true)
        }
        groupOfPictures.append(prepared)

        guard let sampleBuffer = retimedSample(prepared) else { return }
        hasVideo = true
        lastPresentedTimestampMilliseconds = prepared.sourceTimestampMilliseconds

        layerStates = layerStates.filter { $0.value.layer != nil }
        for identifier in layerStates.keys {
            layerStates[identifier]?.pendingSamples.append(sampleBuffer)
            if (layerStates[identifier]?.pendingSamples.count ?? 0) > Self.maximumPendingVideoFrames {
                enterRecovery(reason: "display_layer_backlog")
                return
            }
            drainLayer(identifier)
        }
    }

    private func drainLayer(_ identifier: ObjectIdentifier) {
        guard var state = layerStates[identifier], let layer = state.layer else {
            layerStates.removeValue(forKey: identifier)
            return
        }
        if layer.status == .failed {
            enterRecovery(reason: "display_layer_failed")
            return
        }
        while layer.isReadyForMoreMediaData, !state.pendingSamples.isEmpty {
            layer.enqueue(state.pendingSamples.removeFirst())
        }
        layerStates[identifier] = state
    }

    private func enterRecovery(reason: String) {
        guard !waitingForKeyFrame else { return }
        waitingForKeyFrame = true
        recoveryCount += 1
        pendingVideo.removeAll(keepingCapacity: true)
        groupOfPictures.removeAll(keepingCapacity: true)
        for identifier in layerStates.keys {
            layerStates[identifier]?.pendingSamples.removeAll(keepingCapacity: true)
            layerStates[identifier]?.layer?.flushAndRemoveImage()
        }
        onKeyFrameNeeded?(
            reason,
            min(lastPresentedTimestampMilliseconds, currentSourceTimestampMilliseconds())
        )
    }

    private func startReportTimer() {
        reportTimer?.invalidate()
        reportTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendPlaybackReport()
            }
        }
    }

    private func sendPlaybackReport() {
        guard playbackStarted else { return }
        let currentTimestamp = currentSourceTimestampMilliseconds()
        let videoBuffer = max(0, Int(latestVideoTimestampMilliseconds - currentTimestamp))
        let audioBuffer = max(0, Int(latestAudioTimestampMilliseconds - currentTimestamp))
        let audioBufferLow = audioBuffer < 50
        if audioBufferLow, !wasAudioBufferLow {
            underrunCount += 1
        }
        wasAudioBufferLow = audioBufferLow
        let pendingTimestamps = layerStates.values.flatMap { state in
            state.pendingSamples.map { Int64(CMTimeGetSeconds($0.presentationTimeStamp) * 1_000) }
        }
        let decoderBacklog: Int
        if let minimum = pendingTimestamps.min(), let maximum = pendingTimestamps.max() {
            decoderBacklog = max(0, Int(maximum - minimum))
        } else {
            decoderBacklog = 0
        }

        onReport?(
            iOSCinemaPlaybackReport(
                videoBufferMilliseconds: videoBuffer,
                audioBufferMilliseconds: audioBuffer,
                decoderBacklogMilliseconds: decoderBacklog,
                underruns: underrunCount,
                recoveries: recoveryCount,
                lastPresentedTimestampMilliseconds: min(
                    latestVideoTimestampMilliseconds,
                    currentTimestamp
                )
            )
        )
    }

    private func currentSourceTimestampMilliseconds() -> Int64 {
        guard sourcePlaybackOriginMilliseconds != nil else {
            return sourcePlaybackOriginMilliseconds ?? 0
        }
        return Int64(CMTimeGetSeconds(CMTimebaseGetTime(playbackTimebase)) * 1_000)
    }

    private func milliseconds(forFrames frames: Int) -> Int64 {
        guard audioSampleRate > 0 else { return 0 }
        return Int64(Double(frames) / Double(audioSampleRate) * 1_000)
    }

    private func retimedSample(_ prepared: PreparedVideo) -> CMSampleBuffer? {
        guard sourcePlaybackOriginMilliseconds != nil else { return nil }
        return prepared.sampleBuffer
    }

    private func makeSampleBuffer(
        avccData: Data,
        timestampMilliseconds: Int64,
        isKeyFrame: Bool,
        formatDescription: CMVideoFormatDescription
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let replaceStatus = avccData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: timestampMilliseconds, timescale: 1_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccData.count
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }

        if !isKeyFrame,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let attachment = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    private func convertAnnexBToAVCC(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }
        var result = Data()
        var cursor = 0

        func startCodeLength(at index: Int) -> Int? {
            guard index + 3 <= bytes.count else { return nil }
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                return 4
            }
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                return 3
            }
            return nil
        }

        while cursor < bytes.count {
            while cursor < bytes.count, startCodeLength(at: cursor) == nil {
                cursor += 1
            }
            guard cursor < bytes.count, let prefixLength = startCodeLength(at: cursor) else { break }
            let nalStart = cursor + prefixLength
            var next = nalStart
            while next < bytes.count, startCodeLength(at: next) == nil {
                next += 1
            }
            guard next > nalStart else {
                cursor = next
                continue
            }
            var length = UInt32(next - nalStart).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(contentsOf: bytes[nalStart..<next])
            cursor = next
        }
        return result.isEmpty ? nil : result
    }
}

struct iOSVideoSurface: UIViewRepresentable {
    let player: iOSMediaPlayer

    final class Coordinator {
        let player: iOSMediaPlayer

        init(player: iOSMediaPlayer) {
            self.player = player
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player)
    }

    func makeUIView(context: Context) -> SampleBufferView {
        let view = SampleBufferView()
        player.register(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferView, context: Context) {
        _ = uiView
        _ = context
    }

    static func dismantleUIView(_ uiView: SampleBufferView, coordinator: Coordinator) {
        coordinator.player.unregister(uiView.displayLayer)
        uiView.displayLayer.flushAndRemoveImage()
    }
}

final class SampleBufferView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
    }
}
