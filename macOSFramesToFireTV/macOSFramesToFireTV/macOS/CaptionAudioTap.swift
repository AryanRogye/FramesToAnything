#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation

/// Only four retained capture buffers may await conversion. Admission never waits.
/// Conversion and history access are serialized separately from capture and inference.
nonisolated final class CaptionAudioTap: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aryanrogye.captions.audio", qos: .background)
    private let slots = DispatchSemaphore(value: 4)
    private let admissionLock = NSLock()
    private var closed = false
    private var window = CaptionAudioWindow()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var expectedPTS: Double?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false)!
    private var reportedConversionFailure = false

    func close() {
        admissionLock.withLock { closed = true }
    }

    func offer(_ buffer: CMSampleBuffer) {
        // No waiting even if stop is concurrently closing admission.
        guard admissionLock.try() else { return }
        let acceptsAudio = !closed
        admissionLock.unlock()
        guard acceptsAudio else { return }
        guard slots.wait(timeout: .now()) == .success else { return }
        let retained = RetainedCaptionBuffer(buffer: buffer)
        queue.async { [self] in
            defer { slots.signal() }
            autoreleasepool { convert(retained.buffer) }
        }
    }

    func snapshot() async -> CaptionAudioWindow {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: window) }
        }
    }

    private func convert(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let count = CMSampleBufferGetNumSamples(sample)
        guard pts.isFinite, count > 0,
              let description = CMSampleBufferGetFormatDescription(sample) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.sampleRate > 0, count <= Int(format.sampleRate),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        input.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(count), into: input.mutableAudioBufferList
        ) == noErr else { reportFailure(); return }
        if inputFormat != format {
            converter = AVAudioConverter(from: format, to: outputFormat)
            converter?.primeMethod = .none
            inputFormat = format
        }
        guard let converter else { reportFailure(); return }
        if let expectedPTS, abs(expectedPTS - pts) > 0.002 { converter.reset() }
        expectedPTS = pts + Double(count) / format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(count) * 16_000 / format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            guard !supplied else { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, let samples = output.floatChannelData?[0] else {
            reportFailure(); return
        }
        window.append(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))), at: pts)
    }

    private func reportFailure() {
        guard !reportedConversionFailure else { return }
        reportedConversionFailure = true
        print("[Captions] Unsupported/failed audio conversion; media streaming is unaffected.")
    }
}

nonisolated private struct RetainedCaptionBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}
#endif
