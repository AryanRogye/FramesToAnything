import AVFoundation
import CoreMedia
import XCTest
@testable import PlaybackPolicy

final class CaptionAudioTapTests: XCTestCase, @unchecked Sendable {
    func testStereoSystemAudioConvertsContinuouslyAtBothCommonRates() async throws {
        for rate in [48_000.0, 44_100.0] {
            let tap = CaptionAudioTap()
            for index in 0..<100 {
                tap.offer(try sample(rate: rate, pts: 100 + Double(index) / 100))
                _ = await tap.snapshot()
            }
            let window = await tap.snapshot()
            XCTAssertEqual(window.generation, 1, "Unexpected gaps at \(rate) Hz")
            XCTAssertEqual(window.samples.count, 16_000, accuracy: 32)
            XCTAssertEqual(window.start, 100, accuracy: 0.002)
            XCTAssertEqual(window.end, 101, accuracy: 0.002)
            XCTAssertTrue(window.samples.allSatisfy(\.isFinite))
            XCTAssertGreaterThan(window.samples.map(abs).max() ?? 0, 0.1)
            tap.close()
            tap.offer(try sample(rate: rate, pts: 200))
            let closed = await tap.snapshot()
            XCTAssertEqual(closed.end, window.end)
        }
    }

    private func sample(rate: Double, pts: Double) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: rate, channels: 2, interleaved: false))
        let count = Int(rate / 100)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count)))
        pcm.frameLength = UInt32(count)
        for channel in 0..<2 {
            for i in 0..<count { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 0.1)) * 0.2 }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                        presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer), noErr)
        let sample = try XCTUnwrap(buffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList), noErr)
        return sample
    }
}
