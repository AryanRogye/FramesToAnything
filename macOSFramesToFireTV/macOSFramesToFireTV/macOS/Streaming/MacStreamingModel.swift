#if os(macOS)
import AppKit
import Observation
import Network
import SnapCore
import SwiftUI

@Observable
@MainActor
final class MacStreamingModel {
    private let transport = MacFireTVTransport()
    private let capture = ScreenRecordService()
    private let captions = LiveCaptionExperiment()

    var devices: [MacFireTVDevice] = []
    var selectedDeviceID: String?
    // Do not retain a sample LAN address here: DHCP commonly changes the Fire
    // TV address, and a believable stale default makes discovery failures look
    // like receiver failures.
    var manualAddress = ""
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
    private var isStopping = false
    private var isApplyingAdaptiveQuality = false
    private var pendingAdaptiveQuality: (MacStreamQuality, Int)?

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
            self.connectionState = state
            if case .failed = state {
                self.isStreaming = false
                self.captions.stop()
                Task { await self.capture.stopRecording() }
            }
            if state == .disconnected {
                self.isStreaming = false
                self.captions.stop()
                Task { await self.capture.stopRecording() }
            }
        }
        transport.onAdaptiveQualityChanged = { [weak self] quality, bitRate in
            self?.applyAdaptiveQuality(quality, bitRate: bitRate)
        }
        capture.onScreenFrame = { [weak self] frame in
            guard frame.shouldAppend,
                  let imageBuffer = frame.imageBuffer,
                  let self else { return }
            guard self.connectionState.isConnected else { return }
            self.transport.sendVideo(
                imageBuffer,
                timestamp: frame.presentationTimeStamp
            )
            if !self.isStreaming { self.isStreaming = true }
        }
        capture.onAudioFrame = { [weak self] frame in
            guard let self else { return }
            self.transport.sendAudio(frame.buffer)
            self.captions.offer(frame.buffer)
        }
        transport.startDiscovery()
    }

    var canPair: Bool {
        selectedReceiverIsRemembered ||
            (pairingCode.count == 6 && (!needsManualAddress || validManualHost != nil))
    }

    var selectedReceiverName: String {
        selectedDevice?.name ?? "Fire TV"
    }

    var needsManualAddress: Bool { selectedDevice == nil }

    var menuBarSymbol: String {
        if isStreaming { return "dot.radiowaves.left.and.right" }
        if connectionState.isConnected { return "display" }
        return "display.trianglebadge.exclamationmark"
    }

    var statusMessage: String {
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
        case .waitingForReceiver, .connecting, .authenticating: true
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

    private var validManualHost: String? {
        let value = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
        manualAddress = ""
        if !device.isRemembered {
            pairingCode = ""
        }
    }

    func prepareManualPairing() {
        selectedDeviceID = nil
        manualAddress = ""
        pairingCode = ""
    }

    func pair() {
        guard canPair else { return }
        if let selectedDevice {
            transport.connect(to: selectedDevice, code: pairingCode)
        } else if let validManualHost {
            transport.connectDirect(host: validManualHost, code: pairingCode)
        }
    }

    func resetSelectedReceiverForPairing() {
        guard let selectedDevice else { return }
        transport.forgetSavedConnection(to: selectedDevice)
        pairingCode = ""
        connectionState = .disconnected
    }

    func startStreaming() {
        guard connectionState.isConnected else { return }
        activeQuality = selectedQuality
        activeBitRate = selectedQuality.averageBitRate
        transport.configureVideo(maximumQuality: selectedQuality)
        if captionsEnabled { captions.start(mode: selectedCaptionMode) }
        capture.startRecording(
            scale: selectedQuality.captureScale,
            showsCursor: true,
            capturesAudio: true,
            fps: .fps60
        )
    }

    private func applyAdaptiveQuality(_ quality: MacStreamQuality, bitRate: Int) {
        activeBitRate = bitRate
        guard isStreaming, quality != activeQuality else {
            activeQuality = quality
            return
        }
        guard !isApplyingAdaptiveQuality else {
            pendingAdaptiveQuality = (quality, bitRate)
            return
        }
        isApplyingAdaptiveQuality = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await capture.stopRecording()
            activeQuality = quality
            guard !isStopping, connectionState.isConnected else {
                isApplyingAdaptiveQuality = false
                return
            }
            capture.startRecording(
                scale: quality.captureScale,
                showsCursor: true,
                capturesAudio: true,
                fps: .fps60
            )
            isApplyingAdaptiveQuality = false
            if let pending = pendingAdaptiveQuality {
                pendingAdaptiveQuality = nil
                applyAdaptiveQuality(pending.0, bitRate: pending.1)
            }
        }
    }

    func stopStreaming() {
        guard !isStopping else { return }
        isStopping = true
        captions.stop()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await capture.stopRecording()
            isStreaming = false
            isStopping = false
            transport.disconnect()
        }
    }

    func stop() {
        if isStreaming {
            stopStreaming()
        } else {
            transport.disconnect()
        }
    }
}
#endif
