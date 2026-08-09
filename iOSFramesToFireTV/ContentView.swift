//
//  ContentView.swift
//  iOSFramesToFireTV
//
//  Created by Aryan Rogye on 7/25/26.
//

import Observation
import ReplayKit
import SwiftUI
import UIKit

struct ContentView: View {
    @State private var model = ViewModel()
    @FocusState private var isPairingCodeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Choose your TV, pair with its current code, then start the system broadcast.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 18) {
                        StepHeader(number: 1, title: "Choose a Fire TV")

                        if model.devices.isEmpty {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Searching your local network…")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        } else {
                            ForEach(model.devices) { device in
                                Button {
                                    model.select(device)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "tv")
                                            .frame(width: 24)
                                        Text(device.name)
                                            .fontWeight(.medium)
                                        Spacer()
                                        Image(
                                            systemName: model.selectedDevice?.id == device.id
                                                ? "checkmark.circle.fill"
                                                : "circle"
                                        )
                                        .foregroundStyle(
                                            model.selectedDevice?.id == device.id
                                                ? Color.accentColor
                                                : Color.secondary
                                        )
                                    }
                                    .padding(14)
                                    .background(
                                        model.selectedDevice?.id == device.id
                                            ? Color.accentColor.opacity(0.1)
                                            : Color(uiColor: .tertiarySystemFill)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Or connect by address")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("192.168.1.100", text: $model.manualAddress)
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(12)
                                .background(Color(uiColor: .tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        Divider()

                        StepHeader(number: 2, title: "Enter the pairing code")

                        TextField("000000", text: $model.pairingCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.center)
                            .focused($isPairingCodeFocused)
                            .padding(.vertical, 13)
                            .background(Color(uiColor: .tertiarySystemFill))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(
                                        isPairingCodeFocused
                                            ? Color.accentColor
                                            : Color.clear,
                                        lineWidth: 2
                                    )
                            }
                            .onChange(of: model.pairingCode) { _, newValue in
                                let digits = String(newValue.filter(\.isNumber).prefix(6))
                                if digits != newValue {
                                    model.pairingCode = digits
                                }
                            }

                        Button {
                            isPairingCodeFocused = false
                            model.pair()
                            UINotificationFeedbackGenerator()
                                .notificationOccurred(.success)
                        } label: {
                            Label(
                                model.isPaired ? "Paired and ready" : "Pair with Fire TV",
                                systemImage: model.isPaired ? "checkmark.shield.fill" : "lock.shield"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(model.isPaired ? .green : .accentColor)
                        .disabled(!model.canPair || model.isPaired)

                        Divider()

                        StepHeader(number: 3, title: "Broadcast your iPhone")

                        if model.isPaired {
                            BroadcastPickerButton()
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)

                            Text("Choose FireTVBroadcast, then tap Start Broadcast. App audio is included automatically with hardware H.264 video at up to 60 fps.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(
                                "Pair with the code above to continue",
                                systemImage: "lock.fill"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22))

                    Label(
                        "Video and audio are encrypted and stay on your local network.",
                        systemImage: "lock.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Stream to Fire TV")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { model.startDiscovery() }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isPairingCodeFocused = false
                    }
                }
            }
        }
    }
}

private struct StepHeader: View {
    let number: Int
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())

            Text(title)
                .font(.headline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number), \(title)")
    }
}

@Observable
@MainActor
final class ViewModel {
    private let transport: Transport

    var devices: [FireTVDevice] = []
    var selectedDevice: FireTVDevice?
    var pairingCode = "" {
        didSet {
            if pairingCode != pairedCode {
                invalidatePairing()
            }
        }
    }
    var manualAddress = "192.168.68.112" {
        didSet {
            if manualAddress != pairedManualAddress {
                invalidatePairing()
            }
        }
    }
    var isPaired = false

    private var pairedCode = ""
    private var pairedDeviceID: String?
    private var pairedManualAddress = ""

    init() {
        let transport = Transport()
        self.transport = transport

        transport.onDevicesChanged = { [weak self] devices in
            self?.devices = devices
            if let selected = self?.selectedDevice,
               !devices.contains(where: { $0.id == selected.id }) {
                self?.selectedDevice = nil
                self?.invalidatePairing()
            }
        }
    }

    var canPair: Bool {
        (selectedDevice != nil || !manualAddress.trimmingCharacters(in: .whitespaces).isEmpty) &&
            pairingCode.filter(\.isNumber).count == 6
    }

    func startDiscovery() {
        transport.startDiscovery()
    }

    func select(_ device: FireTVDevice) {
        if selectedDevice?.id != device.id {
            invalidatePairing()
        }
        selectedDevice = device
    }

    func pair() {
        guard canPair else { return }
        pairedCode = pairingCode
        pairedDeviceID = selectedDevice?.id
        pairedManualAddress = selectedDevice == nil
            ? manualAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        saveBroadcastConfiguration()
        isPaired = true
    }

    private func invalidatePairing() {
        guard isPaired || !pairedCode.isEmpty || pairedDeviceID != nil else {
            return
        }
        isPaired = false
        pairedCode = ""
        pairedDeviceID = nil
        pairedManualAddress = ""
        clearBroadcastConfiguration()
    }

    private func saveBroadcastConfiguration() {
        guard let defaults = UserDefaults(
            suiteName: "group.com.aryanrogye.iOSFramesToFireTV"
        ) else {
            return
        }

        if let selectedDevice {
            defaults.set(selectedDevice.name, forKey: "broadcast.serviceName")
            defaults.removeObject(forKey: "broadcast.manualHost")
        } else {
            defaults.removeObject(forKey: "broadcast.serviceName")
            defaults.set(
                manualAddress.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: "broadcast.manualHost"
            )
        }

        let normalizedCode = pairingCode.filter(\.isNumber)
        if normalizedCode.count == 6 {
            defaults.set(normalizedCode, forKey: "broadcast.pairingCode")
        } else {
            defaults.removeObject(forKey: "broadcast.pairingCode")
        }
    }

    private func clearBroadcastConfiguration() {
        guard let defaults = UserDefaults(
            suiteName: "group.com.aryanrogye.iOSFramesToFireTV"
        ) else {
            return
        }
        defaults.removeObject(forKey: "broadcast.serviceName")
        defaults.removeObject(forKey: "broadcast.manualHost")
        defaults.removeObject(forKey: "broadcast.pairingCode")
    }
}

private struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension =
            "com.aryanrogye.iOSFramesToFireTV.FireTVBroadcast"
        picker.showsMicrophoneButton = false
        picker.tintColor = .systemBlue
        configureButton(in: picker)
        return picker
    }

    func updateUIView(
        _ picker: RPSystemBroadcastPickerView,
        context: Context
    ) {
        picker.preferredExtension =
            "com.aryanrogye.iOSFramesToFireTV.FireTVBroadcast"
        picker.showsMicrophoneButton = false
        configureButton(in: picker)
    }

    private func configureButton(in picker: RPSystemBroadcastPickerView) {
        guard let button = findButton(in: picker) else { return }
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Start Broadcast"
        configuration.image = UIImage(systemName: "dot.radiowaves.left.and.right")
        configuration.imagePadding = 9
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = .systemBlue
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.accessibilityLabel = "Start broadcasting this iPhone"
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        button.frame = picker.bounds
    }

    private func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(in: subview) {
                return button
            }
        }
        return nil
    }
}

#Preview {
    ContentView()
}
