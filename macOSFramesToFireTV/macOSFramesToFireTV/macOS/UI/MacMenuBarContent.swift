#if os(macOS)
import AppKit
import SwiftUI

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

            Button("Allow Incoming Connections", systemImage: "antenna.radiowaves.left.and.right") {
                model.resumeConnections()
            }
            .disabled(!model.serverPaused)

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

            Menu("Capture Display", systemImage: "display") {
                Button {
                    model.chooseDisplay(nil)
                } label: {
                    Label("Follow Main Display", systemImage: model.selectedDisplayID == nil ? "checkmark" : "display")
                }

                Button {
                    model.createVirtualDisplayAndStream()
                } label: {
                    Label("Create Virtual Display And Stream", systemImage: "globe")
                }
                .disabled(model.virtualController != nil || model.isCreatingVirtualController)

                if model.isCreatingVirtualController {
                    Button("Cancel Virtual Display Setup") {
                        model.cancelVirtualDisplaySetup()
                    }
                }

                if model.virtualController != nil {
                    Divider()
                    Button("Open Virtual Display") {
                        openWindow(id: MacVirtualDisplayWindow.id)
                    }
                    Button("Stop Virtual Display", systemImage: "stop.fill") {
                        model.chooseDisplay(nil)
                    }
                }

                Divider()

                ForEach(model.availableDisplays) { display in
                    Button {
                        model.chooseDisplay(display.id)
                    } label: {
                        Label(
                            display.isMain ? "\(display.name) (Main)" : display.name,
                            systemImage: model.selectedDisplayID == display.id ? "checkmark" : "display"
                        )
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                model.refreshDisplays()
            }

            Toggle("Live Captions", isOn: $model.captionsEnabled)

            Picker("Caption Mode", selection: $model.selectedCaptionMode) {
                ForEach(CaptionMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            if model.isStreaming {
                Button("Stop Streaming", systemImage: "stop.fill", role: .destructive) {
                    model.stopStreaming()
                }
            } else {
                Button("Retry Capture", systemImage: "play.display") {
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
#endif
