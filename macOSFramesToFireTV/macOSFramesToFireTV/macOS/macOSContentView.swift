#if os(macOS)

import AppKit
import Observation
import Network
import SnapCore
import SwiftUI

enum MacPairingWindow {
    static let id = "pair-receiver"
}

struct MacMenuBarContent: View {
    @Bindable var model: MacStreamingModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(model.statusMessage, systemImage: model.statusSymbol)

        Divider()

        Section("Receivers") {
            if model.devices.isEmpty {
                Text("Searching on this Wi-Fi network…")
            } else {
                ForEach(model.devices) { device in
                    Button {
                        connect(to: device)
                    } label: {
                        Label(
                            device.name,
                            systemImage: device.isRemembered
                                ? "checkmark.shield.fill"
                                : model.deviceSymbol(for: device)
                        )
                    }
                    .disabled(model.isStreaming || model.isBusy)
                }
            }

            Button("Connect by IP Address…", systemImage: "network") {
                model.prepareManualPairing()
                showPairingWindow()
            }
            .disabled(model.isStreaming || model.isBusy)

            if model.selectedReceiverIsRemembered {
                Button("Reset Connection & Pair Again…", systemImage: "arrow.counterclockwise") {
                    model.resetSelectedReceiverForPairing()
                    showPairingWindow()
                }
                .disabled(model.isStreaming)
            }
        }

        Section("Stream") {
            Picker("Maximum Quality", selection: $model.selectedQuality) {
                ForEach(MacStreamQuality.allCases) { quality in
                    Text("\(quality.label) · \(quality.bandwidth)")
                        .tag(quality)
                }
            }
            .disabled(model.isStreaming)

            if model.isStreaming {
                Button("Stop Streaming", systemImage: "stop.fill", role: .destructive) {
                    model.stopStreaming()
                }
            } else {
                Button("Choose Display & Start…", systemImage: "play.display") {
                    model.startStreaming()
                }
                .disabled(!model.connectionState.isConnected)
            }
        }

        Divider()

        Button("Quit Frames to Fire TV") {
            model.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func connect(to device: MacFireTVDevice) {
        model.select(device)
        if device.isRemembered {
            model.pair()
        } else {
            showPairingWindow()
        }
    }

    private func showPairingWindow() {
        openWindow(id: MacPairingWindow.id)
        NSApplication.shared.activate()
    }
}

struct MacPairingView: View {
    @Bindable var model: MacStreamingModel
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var focusedField: Field?

    private enum Field {
        case address
        case code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Pair \(model.selectedReceiverName)", systemImage: "lock.shield")
                    .font(.title2.weight(.semibold))
                Text("You will only need to do this once on this Mac.")
                    .foregroundStyle(.secondary)
            }

            if model.needsManualAddress {
                TextField("Fire TV IP address", text: $model.manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .address)
                    .onSubmit { focusedField = .code }
            }

            TextField("Six-digit code", text: $model.pairingCode)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .code)
                .onChange(of: model.pairingCode) { _, value in
                    model.pairingCode = String(value.filter(\.isNumber).prefix(6))
                }
                .onSubmit { pair() }

            if case .failed(let message) = model.connectionState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    dismissWindow(id: MacPairingWindow.id)
                }
                Spacer()
                Button("Pair & Connect", systemImage: "lock.shield") {
                    pair()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPair || model.isBusy)
            }
        }
        .padding(22)
        .frame(width: 380)
        .task {
            focusedField = model.needsManualAddress ? .address : .code
        }
        .onChange(of: model.connectionState) { _, state in
            if state.isConnected {
                dismissWindow(id: MacPairingWindow.id)
            }
        }
    }

    private func pair() {
        guard model.canPair else { return }
        focusedField = nil
        model.pair()
    }
}

@Observable
@MainActor
final class MacStreamingModel {
    private let transport = MacFireTVTransport()
    private let capture = ScreenRecordService()

    var devices: [MacFireTVDevice] = []
    var selectedDeviceID: String?
    // Do not retain a sample LAN address here: DHCP commonly changes the Fire
    // TV address, and a believable stale default makes discovery failures look
    // like receiver failures.
    var manualAddress = ""
    var pairingCode = ""
    var connectionState: MacFireTVConnectionState = .searching
    var selectedQuality: MacStreamQuality = .fullHD
    private(set) var activeQuality: MacStreamQuality = .fullHD
    private(set) var activeBitRate = 10_000_000
    var isStreaming = false
    private var isStopping = false
    private var isApplyingAdaptiveQuality = false
    private var pendingAdaptiveQuality: (MacStreamQuality, Int)?

    init() {
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
                Task { await self.capture.stopRecording() }
            }
            if state == .disconnected {
                self.isStreaming = false
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

enum MacStreamQuality: String, CaseIterable, Identifiable, Sendable {
    case hd
    case fullHD
    case quadHD
    case ultraHD

    var id: Self { self }

    var label: String {
        switch self {
        case .hd: "720p"
        case .fullHD: "1080p"
        case .quadHD: "1440p"
        case .ultraHD: "4K"
        }
    }

    var detail: String {
        switch self {
        case .hd: "Smoothest on busy Wi-Fi"
        case .fullHD: "Recommended for Twitch"
        case .quadHD: "Sharper text and detail"
        case .ultraHD: "Maximum detail on fast Wi-Fi"
        }
    }

    var bandwidth: String {
        "~\(averageBitRate / 1_000_000) Mbps"
    }

    var captureScale: VideoScale {
        switch self {
        case .hd: .low
        case .fullHD: .normal
        case .quadHD: .medium
        case .ultraHD: .high
        }
    }

    var averageBitRate: Int {
        switch self {
        case .hd: 5_000_000
        case .fullHD: 10_000_000
        case .quadHD: 18_000_000
        case .ultraHD: 32_000_000
        }
    }
}

private extension MacFireTVDevice {
    static func manual(host: String) -> MacFireTVDevice {
        MacFireTVDevice(
            id: "manual:\(host):49218",
            name: "Fire TV at \(host)",
            endpoint: .hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: 49_218)!
            ),
            receiverID: nil
        )
    }
}

#Preview("Pair Receiver") {
    MacPairingView(model: MacStreamingModel())
}

#endif
