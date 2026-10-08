#if os(macOS)
import AVFoundation
import CoreMedia
import CoreML
import Foundation
@preconcurrency import WhisperKit

/// Live caption worker controlled by the menu-bar preference. No caption code is called from the video callback.
@MainActor
final class LiveCaptionExperiment {
    var onCaption: (@Sendable (LiveCaptionCue) -> Void)?
    private var tap: CaptionAudioTap?
    private var worker: Task<Void, Never>?
    private var mode: CaptionMode = .englishCaptions

    func changeMode(_ newMode: CaptionMode) {
        guard newMode != mode else { return }
        let wasActive = tap != nil
        stop()
        mode = newMode
        if wasActive { start(mode: newMode) }
    }

    func start(mode: CaptionMode = .englishCaptions) {
        guard tap == nil else { return }
        self.mode = mode
        let tap = CaptionAudioTap()
        self.tap = tap
        let previous = worker
        let onCaption = onCaption
        worker = Task.detached(priority: .background) {
            // Cancellation can take time inside Core ML; never overlap models.
            await previous?.value
            guard !Task.isCancelled else { return }
            await Self.run(tap, mode: mode, onCaption: onCaption)
        }
    }

    func offer(_ buffer: CMSampleBuffer) { tap?.offer(buffer) }

    func stop() {
        tap?.close()
        tap = nil
        worker?.cancel()
    }

    nonisolated private static func run(_ tap: CaptionAudioTap, mode: CaptionMode, onCaption: (@Sendable (LiveCaptionCue) -> Void)?) async {
        defer { tap.close() }
        do {
            print("[Captions] Preparing \(mode.modelName) for \(mode.label); video continues independently.")
            var storage = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("com.aryanrogye.macOSFramesToFireTV/WhisperKit", isDirectory: true)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try storage.setResourceValues(values)
            let folder = try await WhisperKit.download(variant: mode.modelName, downloadBase: storage)
            try Task.checkCancellation()
            let kit = try await WhisperKit(WhisperKitConfig(
                model: mode.modelName, downloadBase: storage, modelFolder: folder.path,
                tokenizerFolder: storage,
                computeOptions: ModelComputeOptions(
                    melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: false, prewarm: false, load: true, download: false
            ))
            try Task.checkCancellation()
            print("[Captions] Ready. \(mode.label) → 16 kHz mono; captions sent to compatible Fire TV receivers.")
            var lastEnd = -Double.infinity
            var confirmedEnd = -Double.infinity
            var generation = -1
            var slowPasses = 0
            var revisions = CaptionRevisionState()
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                let thermal = ProcessInfo.processInfo.thermalState
                guard thermal != .serious && thermal != .critical else {
                    print("[Captions] Disabled for this session: thermal pressure.")
                    return
                }
                let window = await tap.snapshot()
                guard window.samples.count >= 8_000, window.end > lastEnd + 0.4 else { continue }
                if generation != window.generation {
                    confirmedEnd = window.start
                    generation = window.generation
                    revisions.reset()
                }
                if confirmedEnd < window.start {
                    print("[Captions] Skipped old audio to stay current.")
                    confirmedEnd = window.start
                }
                lastEnd = window.end
                // Cheap silence gate; this is deliberately not a speech detector.
                let energy = window.samples.reduce(Float(0)) { $0 + $1 * $1 }
                    / Float(window.samples.count)
                guard energy > 0.00001 else { continue }
                let started = ContinuousClock.now
                let options = DecodingOptions(
                    task: mode == .hindiTranslation ? .translate : .transcribe,
                    language: mode.sourceLanguage, temperatureFallbackCount: 0,
                    sampleLength: 128, skipSpecialTokens: true,
                    withoutTimestamps: false, wordTimestamps: false,
                    clipTimestamps: [Float(max(0, confirmedEnd - window.start))],
                    concurrentWorkerCount: 1, chunkingStrategy: ChunkingStrategy.none
                )
                let results = try await kit.transcribe(
                    audioArray: window.samples, decodeOptions: options,
                    callback: { _ in
                        // Best effort: Core ML work already in flight cannot be preempted.
                        !Task.isCancelled && started.duration(to: .now) < .seconds(2)
                    }
                )
                try Task.checkCancellation()
                let elapsed = started.duration(to: .now)
                // Discard output invalidated by an audio gap/restart while decoding.
                let current = await tap.snapshot()
                guard current.generation == generation else { continue }
                if elapsed >= .seconds(2) {
                    slowPasses += 1
                    print("[Captions] Decode exceeded 2 s; discarding late output (\(slowPasses)/3).")
                    if slowPasses >= 3 {
                        print("[Captions] Disabled for this session: inference cannot keep up.")
                        return
                    }
                    continue
                }
                slowPasses = 0
                var committedText: [String] = []
                var partialText: [String] = []
                var cueStart = window.end
                var cueEnd = window.start
                for segment in results.flatMap(\.segments) {
                    let start = window.start + Double(segment.start)
                    let end = min(window.end, window.start + Double(segment.end))
                    guard end > confirmedEnd, end >= current.start,
                          segment.noSpeechProb < 0.6 else { continue }
                    let text = segment.text.replacingOccurrences(
                        of: #"<\|[^|]+\|>"#, with: "", options: .regularExpression
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !["[MUSIC]", "(MUSIC)", "MUSIC"].contains(text.uppercased()) else { continue }
                    // Keep the newest 750 ms revisable. This is a heuristic, not word agreement.
                    let final = end <= window.end - 0.75
                    cueStart = min(cueStart, start)
                    cueEnd = max(cueEnd, end)
                    if final {
                        confirmedEnd = end
                        committedText.append(text)
                    } else { partialText.append(text) }
                    print("[Captions \(final ? "final" : "partial")] pts=\(Int(start * 1000))..\(Int(end * 1000)) ms decode=\(elapsed): \(text)")
                }
                if cueEnd >= cueStart, let cue = revisions.update(
                    committedText: committedText.joined(separator: " "),
                    partialText: partialText.joined(separator: " "), start: cueStart, end: cueEnd
                ), !Task.isCancelled { onCaption?(cue) }
            }
        } catch is CancellationError {
            // Stop/disconnect deliberately discards the unfinished tail.
        } catch {
            print("[Captions] Disabled for this session: \(error.localizedDescription)")
        }
    }
}

#endif
