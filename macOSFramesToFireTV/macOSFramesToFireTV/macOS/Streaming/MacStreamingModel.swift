#if os(macOS)
import AppKit
import Observation
import Network
import SnapCore
import ScreenCaptureKit
import SwiftUI

@Observable
@MainActor
final class MacStreamingModel {
    private let transport = MacFireTVTransport()
    private var capture = ScreenRecordService()
    private var usesSelectedDisplay = false
    private var captureStartupDeadline: Task<Void, Never>?
    private let captions = LiveCaptionExperiment()

    var devices: [MacFireTVDevice] = []
    var selectedDeviceID: String?
    var pairingCode = ""
    var connectionState: MacFireTVConnectionState = .searching
    var captionsEnabled = (UserDefaults.standard.object(forKey: "captions.enabled") as? Bool) ?? true {
        didSet {
            guard oldValue != captionsEnabled else { return }
            UserDefaults.standard.set(captionsEnabled, forKey: "captions.enabled")
            if captionsEnabled && isStreaming { captions.start(mode: selectedCaptionMode) }
            if !captionsEnabled { captions.stop() }
        }
    }
    var selectedCaptionMode = CaptionMode(
        rawValue: UserDefaults.standard.string(forKey: "captions.mode") ?? ""
    ) ?? .englishCaptions {
        didSet {
            guard oldValue != selectedCaptionMode else { return }
            UserDefaults.standard.set(selectedCaptionMode.rawValue, forKey: "captions.mode")
            captions.changeMode(selectedCaptionMode)
        }
    }
    var selectedQuality: MacStreamQuality = .fullHD
    private(set) var activeQuality: MacStreamQuality = .fullHD
    private(set) var activeBitRate = 10_000_000
    var isStreaming = false {
        didSet {
            if isStreaming && !oldValue && captionsEnabled {
                captions.start(mode: selectedCaptionMode)
            }
        }
    }
    var serverPaused = false
    var captureError: String?
    private var requestedCaptureQuality: MacStreamQuality?
    private var captureGeneration: UInt64 = 0
    private var captureWork: Task<Void, Never>?

    init() {
        let captionTransport = transport
        captions.onCaption = { cue in captionTransport.sendCaption(cue) }
        transport.onDevicesChanged = { [weak self] devices in
            guard let self else { return }
            self.devices = devices
            if self.selectedDeviceID == nil {
                self.selectedDeviceID = devices.first?.id
            }
        }
        transport.onStateChanged = { [weak self] state in
            guard let self else { return }
            let wasConnected = self.connectionState.isConnected
            self.connectionState = state
            if state.isConnected {
                self.captureError = nil
                self.scheduleCapture(start: true)
            } else if case .failed = state {
                self.scheduleCapture(start: false)
            } else if state == .disconnected || wasConnected {
                self.scheduleCapture(start: false)
            }

        }
        transport.onAdaptiveQualityChanged = { [weak self] quality, bitRate in
            self?.applyAdaptiveQuality(quality, bitRate: bitRate)
        }
        configureCaptureCallbacks()
        transport.startServer()
        transport.startDiscovery()
    }

    private func configureCaptureCallbacks() {
        let generation = captureGeneration
        capture.onScreenFrame = { [weak self] frame in
            guard frame.shouldAppend,
                  let imageBuffer = frame.imageBuffer,
                  let self, generation == self.captureGeneration else { return }
            guard self.connectionState.isConnected else { return }
            self.transport.sendVideo(
                imageBuffer,
                timestamp: frame.presentationTimeStamp
            )
            if !self.isStreaming { self.isStreaming = true }
        }
        capture.onAudioFrame = { [weak self] frame in
            guard let self, generation == self.captureGeneration, self.connectionState.isConnected else { return }
            self.transport.sendAudio(frame.buffer)
            self.captions.offer(frame.buffer)
        }
    }

    var canPair: Bool {
        selectedDevice != nil && (selectedReceiverIsRemembered || pairingCode.count == 6)
    }

    var selectedReceiverName: String {
        selectedDevice?.name ?? "Fire TV"
    }

    var menuBarSymbol: String {
        if isStreaming { return "dot.radiowaves.left.and.right" }
        if connectionState.isConnected { return "display" }
        return "display.trianglebadge.exclamationmark"
    }

    var statusMessage: String {
        if let captureError { return captureError }
        if serverPaused { return "Incoming connections paused" }
        if case .searching = connectionState, let selectedDevice {
            return selectedDevice.isRemembered
                ? "\(selectedDevice.name) is ready to connect"
                : "\(selectedDevice.name) found — enter its code once"
        }
        return connectionState.message
    }

    var isBusy: Bool {
        switch connectionState {
        case .searching: devices.isEmpty
        case .connecting, .authenticating: true
        case .waitingForReceiver: false
        default: false
        }
    }

    var statusSymbol: String {
        if isStreaming { return "dot.radiowaves.left.and.right" }
        return switch connectionState {
        case .connected: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .disconnected: "bolt.horizontal.circle"
        case .searching where !devices.isEmpty: "checkmark.circle.fill"
        default: "antenna.radiowaves.left.and.right"
        }
    }

    var statusColor: Color {
        if isStreaming { return .red }
        return switch connectionState {
        case .connected: .green
        case .failed: .orange
        case .searching where !devices.isEmpty: .green
        default: .accentColor
        }
    }

    private var selectedDevice: MacFireTVDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var selectedReceiverIsRemembered: Bool {
        selectedDevice?.isRemembered == true
    }

    func startDiscovery() {
        transport.startDiscovery()
    }

    func deviceSymbol(for device: MacFireTVDevice) -> String {
        device.name.localizedCaseInsensitiveContains("iphone") ||
            device.name.localizedCaseInsensitiveContains("ipad")
            ? "iphone"
            : "tv"
    }

    func select(_ device: MacFireTVDevice) {
        selectedDeviceID = device.id
        if !device.isRemembered {
            pairingCode = ""
        }
    }

    func pair() {
        guard canPair else { return }
        serverPaused = false
        if let selectedDevice {
            transport.connect(to: selectedDevice, code: pairingCode)
        }
    }

    func resetSelectedReceiverForPairing() {
        guard let selectedDevice else { return }
        transport.forgetSavedConnection(to: selectedDevice)
        pairingCode = ""
        connectionState = .disconnected
    }

    func resumeConnections() {
        serverPaused = false
        captureError = nil
        transport.startServer()
    }

    func startStreaming() {
        guard connectionState.isConnected else { return }
        scheduleCapture(start: true)
    }

    /// Every capture operation waits for preceding cleanup. Old sessions cannot
    /// finish stopping after a replacement session has started.
    func chooseDisplay() {
        guard connectionState.isConnected else { return }
        scheduleCapture(start: true, chooseDisplay: true)
    }

    private func scheduleCapture(start: Bool, quality: MacStreamQuality? = nil, chooseDisplay: Bool = false, resetQuality: Bool = true) {
        requestedCaptureQuality = start ? (quality ?? selectedQuality) : nil
        captureStartupDeadline?.cancel()
        captureGeneration &+= 1
        let generation = captureGeneration
        let previous = captureWork
        isStreaming = false
        if !start || resetQuality { captions.stop() }
        capture.onScreenFrame = nil
        capture.onAudioFrame = nil
        if start {
            captureStartupDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(chooseDisplay ? 120 : 15)) } catch { return }
                guard let self, generation == captureGeneration, !isStreaming else { return }
                captureError = "Capture did not produce video. Reconnecting…"
                captureWork?.cancel()
                transport.endFailedCapture()
            }
        }
        captureWork = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            SCContentSharingPicker.shared.remove(capture)
            SCContentSharingPicker.shared.isActive = false
            await capture.stopRecording()
            guard generation == captureGeneration, !Task.isCancelled, start,
                  connectionState.isConnected, !serverPaused else { return }
            if chooseDisplay {
                capture = ScreenRecordService()
                usesSelectedDisplay = true
            }
            configureCaptureCallbacks()
            let quality = quality ?? selectedQuality
            activeQuality = quality
            if resetQuality {
                activeBitRate = quality.averageBitRate
                transport.configureVideo(maximumQuality: selectedQuality)
            }
            do {
                if usesSelectedDisplay && (chooseDisplay || capture.getCachedFilter() != nil) {
                    capture.startRecording(scale: quality.captureScale, showsCursor: true,
                                           capturesAudio: true, fps: .fps60)
                } else {
                    usesSelectedDisplay = false
                    try await capture.startRecordingMainDisplay(
                        scale: quality.captureScale, showsCursor: true,
                        capturesAudio: true, fps: .fps60
                    )
                }
                guard generation == captureGeneration, connectionState.isConnected else {
                    await capture.stopRecording()
                    return
                }
            } catch {
                guard generation == captureGeneration, !Task.isCancelled else { return }
                captureError = error.localizedDescription
                serverPaused = true
                transport.disconnect()
            }
        }
    }

    private func applyAdaptiveQuality(_ quality: MacStreamQuality, bitRate: Int) {
        activeBitRate = bitRate
        guard connectionState.isConnected else {
            activeQuality = quality
            return
        }
        // Quality changes during startup/cleanup must replace the pending
        // capture too; otherwise the encoder and capture scale can diverge.
        guard quality != (requestedCaptureQuality ?? activeQuality) else { return }
        scheduleCapture(start: true, quality: quality, resetQuality: false)
    }

    func stopStreaming() {
        serverPaused = true
        transport.disconnect()
        scheduleCapture(start: false)
    }

    func stop() {
        scheduleCapture(start: false)
        transport.shutdown()
    }
}
#endif
