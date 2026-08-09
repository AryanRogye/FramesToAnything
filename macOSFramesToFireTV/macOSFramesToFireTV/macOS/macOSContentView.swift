#if os(macOS)

import Observation
import Network
import SnapCore
import SwiftUI

struct MacContentView: View {
    @State private var model = MacStreamingModel()
    @FocusState private var focusedField: Field?

    private enum Field { case address, code }

    var body: some View {
        HSplitView {
            receiverSidebar
                .frame(minWidth: 245, idealWidth: 270, maxWidth: 320)

            streamPanel
                .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.startDiscovery() }
        .onDisappear { model.stop() }
    }

    private var receiverSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Receivers")
                    .font(.title2.weight(.semibold))
                Text("On this Wi-Fi network")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 14)

            if model.devices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            } else {
                List(model.devices, selection: $model.selectedDeviceID) { device in
                    Label(device.name, systemImage: "tv")
                        .tag(device.id)
                        .padding(.vertical, 4)
                }
                .listStyle(.sidebar)
            }

            Spacer(minLength: 12)
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Manual address")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("192.168.1.100", text: $model.manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .address)
                    .onSubmit { focusedField = .code }
                Text("Used if Bonjour discovery is blocked.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private var streamPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Stream to Fire TV")
                        .font(.largeTitle.weight(.semibold))
                    Text("Your display and system audio stay encrypted on your local network.")
                        .foregroundStyle(.secondary)
                }

                connectionStatus

                VStack(alignment: .leading, spacing: 12) {
                    Text("Pairing code")
                        .font(.headline)
                    TextField("000000", text: $model.pairingCode)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    focusedField == .code ? Color.accentColor : .clear,
                                    lineWidth: 2
                                )
                        }
                        .focused($focusedField, equals: .code)
                        .onChange(of: model.pairingCode) { _, value in
                            model.pairingCode = String(value.filter(\.isNumber).prefix(6))
                        }
                        .onSubmit { model.pair() }

                    Button {
                        focusedField = nil
                        model.pair()
                    } label: {
                        Label("Pair with Fire TV", systemImage: "lock.shield")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.blue)
                    .disabled(!model.canPair || model.connectionState.isConnected)
                }

                Divider()

                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Display & audio")
                                .font(.headline)
                            Text("60 fps · H.264 · automatic system audio")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(model.isStreaming ? .green : .secondary)
                            .accessibilityLabel("System audio included")
                    }

                    Picker("Quality", selection: $model.selectedQuality) {
                        ForEach(MacStreamQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isStreaming)
                    .accessibilityLabel("Streaming quality")

                    HStack {
                        Text(model.selectedQuality.detail)
                        Spacer()
                        Text(model.selectedQuality.bandwidth)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if model.isStreaming {
                        Button(role: .destructive) {
                            model.stopStreaming()
                        } label: {
                            Label("Stop Streaming", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button {
                            model.startStreaming()
                        } label: {
                            Label("Choose Display & Start", systemImage: "play.display")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.blue)
                        .disabled(!model.connectionState.isConnected)
                    }

                    Text("macOS will ask which display to share. Audio from Twitch and other apps is sent automatically; your microphone is not included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(32)
            .frame(maxWidth: 660, alignment: .leading)
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 11) {
            Image(systemName: model.statusSymbol)
                .foregroundStyle(model.statusColor)
                .symbolEffect(.pulse, isActive: model.isBusy)
            Text(model.connectionState.message)
                .font(.subheadline.weight(.medium))
            Spacer()
            if model.isStreaming {
                Text("LIVE")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red, in: Capsule())
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
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
    var isStreaming = false
    private var isStopping = false

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
            if case .failed = state { self.isStreaming = false }
            if state == .disconnected { self.isStreaming = false }
        }
        capture.onScreenFrame = { [weak self] frame in
            guard frame.shouldAppend,
                  let imageBuffer = frame.imageBuffer,
                  let self else { return }
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
    }

    var canPair: Bool {
        pairingCode.count == 6
    }

    var isBusy: Bool {
        switch connectionState {
        case .searching, .waitingForReceiver, .connecting, .authenticating: true
        default: false
        }
    }

    var statusSymbol: String {
        if isStreaming { return "dot.radiowaves.left.and.right" }
        return switch connectionState {
        case .connected: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .disconnected: "bolt.horizontal.circle"
        default: "antenna.radiowaves.left.and.right"
        }
    }

    var statusColor: Color {
        if isStreaming { return .red }
        return switch connectionState {
        case .connected: .green
        case .failed: .orange
        default: .accentColor
        }
    }

    private var selectedDevice: MacFireTVDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    private var validManualHost: String? {
        let value = manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func startDiscovery() {
        transport.startDiscovery()
    }

    func pair() {
        guard pairingCode.count == 6 else { return }
        transport.waitForFireTV(code: pairingCode)
    }

    func startStreaming() {
        guard connectionState.isConnected else { return }
        transport.configureVideo(averageBitRate: selectedQuality.averageBitRate)
        capture.startRecording(
            scale: selectedQuality.captureScale,
            showsCursor: true,
            capturesAudio: true,
            fps: .fps60
        )
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
            )
        )
    }
}

#Preview {
    MacContentView()
}

#endif
