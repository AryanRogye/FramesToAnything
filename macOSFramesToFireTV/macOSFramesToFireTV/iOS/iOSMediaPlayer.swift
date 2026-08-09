#if os(iOS)

import AVFoundation
import CoreMedia
import Observation
import SwiftUI
import UIKit

@Observable
@MainActor
final class iOSMediaPlayer {
    private(set) var hasVideo = false
    private(set) var videoSize = CGSize.zero
    private(set) var lastError: String?

    private var videoFormat: CMVideoFormatDescription?
    private var waitingForKeyFrame = true
    private let displayLayers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()

    private let audioEngine = AVAudioEngine()
    private let audioNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var scheduledAudioBuffers = 0

    init() {
        audioEngine.attach(audioNode)
    }

    func register(_ layer: AVSampleBufferDisplayLayer) {
        layer.videoGravity = .resizeAspect
        displayLayers.add(layer)
    }

    func unregister(_ layer: AVSampleBufferDisplayLayer) {
        displayLayers.remove(layer)
    }

    func configureVideo(
        width: Int,
        height: Int,
        rotationDegrees: Int,
        sps: Data,
        pps: Data
    ) {
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            lastError = "The Mac sent an unsupported video format."
            return
        }

        videoFormat = description
        let rotated = rotationDegrees == 90 || rotationDegrees == 270
        videoSize = rotated
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        waitingForKeyFrame = true
        hasVideo = false
        lastError = nil
        flushVideoLayers()
    }

    func enqueueVideo(_ annexBData: Data, timestampMilliseconds: Int64, isKeyFrame: Bool) {
        guard let videoFormat else { return }
        if waitingForKeyFrame && !isKeyFrame { return }
        guard let avccData = Self.convertAnnexBToAVCC(annexBData), !avccData.isEmpty else {
            lastError = "The Mac sent an unreadable video frame."
            waitingForKeyFrame = true
            return
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return }
        status = avccData.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }
        guard status == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: timestampMilliseconds, timescale: 1_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccData.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: videoFormat,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            if !isKeyFrame {
                CFDictionarySetValue(
                    attachment,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
        }

        let layers = displayLayers.allObjects
        for layer in layers where layer.isReadyForMoreMediaData {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sampleBuffer)
        }
        waitingForKeyFrame = false
        hasVideo = true
        lastError = nil
    }

    func configureAudio(sampleRate: Int, channels: Int) {
        stopAudio()
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            lastError = "The Mac sent an unsupported audio format."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            audioEngine.connect(audioNode, to: audioEngine.mainMixerNode, format: format)
            audioEngine.prepare()
            try audioEngine.start()
            audioNode.play()
            audioFormat = format
        } catch {
            lastError = "Audio could not start: \(error.localizedDescription)"
        }
    }

    func enqueueAudio(_ pcm: Data) {
        guard let audioFormat else { return }
        let bytesPerFrame = Int(audioFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frameCount = pcm.count / bytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
              ) else { return }

        if scheduledAudioBuffers >= Self.maximumScheduledAudioBuffers {
            audioNode.stop()
            audioNode.play()
            scheduledAudioBuffers = 0
        }
        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
        pcm.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: frameCount * bytesPerFrame)
        buffer.frameLength = AVAudioFrameCount(frameCount)
        scheduledAudioBuffers += 1
        audioNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduledAudioBuffers = max(0, self.scheduledAudioBuffers - 1)
            }
        }
    }

    func reset() {
        videoFormat = nil
        waitingForKeyFrame = true
        hasVideo = false
        videoSize = .zero
        flushVideoLayers()
        stopAudio()
    }

    private func flushVideoLayers() {
        displayLayers.allObjects.forEach { $0.flushAndRemoveImage() }
    }

    private func stopAudio() {
        audioNode.stop()
        audioEngine.stop()
        audioEngine.disconnectNodeOutput(audioNode)
        audioFormat = nil
        scheduledAudioBuffers = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func convertAnnexBToAVCC(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }
        var starts: [(offset: Int, prefixLength: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }
        guard !starts.isEmpty else { return nil }

        var result = Data()
        for (position, start) in starts.enumerated() {
            let payloadStart = start.offset + start.prefixLength
            let payloadEnd = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            guard payloadEnd > payloadStart else { continue }
            var length = UInt32(payloadEnd - payloadStart).bigEndian
            result.append(Data(bytes: &length, count: 4))
            result.append(contentsOf: bytes[payloadStart..<payloadEnd])
        }
        return result
    }

    private static let maximumScheduledAudioBuffers = 12
}

struct iOSVideoSurface: UIViewRepresentable {
    let player: iOSMediaPlayer
    var fillScreen = false

    func makeUIView(context: Context) -> SampleBufferView {
        let view = SampleBufferView()
        view.displayLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
        player.register(view.displayLayer)
        return view
    }

    func updateUIView(_ view: SampleBufferView, context: Context) {
        view.displayLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
        player.register(view.displayLayer)
    }

    static func dismantleUIView(_ view: SampleBufferView, coordinator: ()) {
        // The weak layer table removes deallocated surfaces automatically.
    }
}

final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#endif
