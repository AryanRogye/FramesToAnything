#if os(iOS)

import Observation
import SwiftUI

struct iOSReceiverView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = iOSPairingModel()
    @State private var isPresentingFullScreen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    receiverPreview

                    if model.isStreaming {
                        streamingDetails
                    } else {
                        pairingInstructions
                    }
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Mac Receiver")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Code", systemImage: "arrow.clockwise") {
                        model.resetPairing()
                    }
                    .disabled(!model.hasStarted)
                }
            }
        }
        .onAppear { model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.start()
            } else if phase == .background {
                model.stop()
            }
        }
        .fullScreenCover(isPresented: $isPresentingFullScreen) {
            FullScreenMacVideo(player: model.player)
        }
    }

    private var receiverPreview: some View {
        ZStack {
            Color.black

            iOSVideoSurface(player: model.player)
                .opacity(model.player.hasVideo ? 1 : 0)

            if !model.player.hasVideo {
                VStack(spacing: 12) {
                    Image(systemName: model.isStreaming ? "display" : "macbook.and.iphone")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                    Text(model.isStreaming ? "Waiting for the first frame" : "Waiting for your Mac")
                        .font(.headline)
                        .foregroundStyle(.white)

                    ProgressView()
                        .tint(.white)
                }
            }

            if model.player.hasVideo {
                VStack {
                    Spacer()
                    HStack {
                        streamingBadge
                        Spacer()
                        Button {
                            isPresentingFullScreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.headline)
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .accessibilityLabel("Show Mac video full screen")
                    }
                    .padding(14)
                }
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var pairingInstructions: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text("PAIRING CODE")
                    .font(.caption.weight(.semibold))
                    .tracking(1.4)
                    .foregroundStyle(.secondary)

                Text(model.formattedPairingCode)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel("Pairing code \(model.pairingCode)")
            }

            Text("Select this iPhone or iPad on your Mac. Enter the code the first time; this receiver will be remembered.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Label(model.status, systemImage: model.statusSymbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(model.statusColor)
                .multilineTextAlignment(.center)

            if let name = model.pairingDeviceName {
                Label("Pairing with \(name)", systemImage: "laptopcomputer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var streamingDetails: some View {
        VStack(spacing: 12) {
            Label("Mac connected", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            Text(model.player.lastError ?? model.status)
                .font(.subheadline)
                .foregroundStyle(model.player.lastError == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.center)

            Button("End Session", role: .destructive) {
                model.resetPairing()
            }
            .buttonStyle(.bordered)
        }
    }

    private var streamingBadge: some View {
        Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
    }
}

private struct FullScreenMacVideo: View {
    @Environment(\.dismiss) private var dismiss
    let player: iOSMediaPlayer

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            iOSVideoSurface(player: player, fillScreen: false)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding()
            .accessibilityLabel("Close full screen video")
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
    }
}

@Observable
@MainActor
final class iOSPairingModel {
    let player = iOSMediaPlayer()

    var pairingCode = ""
    var status = "Looking for a Mac…"
    var pairingDeviceName: String?
    var isStreaming = false
    var hasStarted = false

    @ObservationIgnored
    private lazy var pairingService = PairingService(
        onPairingCode: { [weak self] code in
            self?.pairingCode = code
        },
        onPairingRequest: { [weak self] name in
            self?.pairingDeviceName = name
        },
        onStatus: { [weak self] status, streaming in
            self?.status = status
            self?.isStreaming = streaming
        },
        onVideoConfiguration: { [weak self] width, height, rotation, sps, pps in
            self?.player.configureVideo(
                width: width,
                height: height,
                rotationDegrees: rotation,
                sps: sps,
                pps: pps
            )
        },
        onVideoFrame: { [weak self] data, timestamp, isKeyFrame in
            self?.player.enqueueVideo(
                data,
                timestampMilliseconds: timestamp,
                isKeyFrame: isKeyFrame
            )
        },
        onAudioConfiguration: { [weak self] sampleRate, channels in
            self?.player.configureAudio(sampleRate: sampleRate, channels: channels)
        },
        onAudioFrame: { [weak self] data in
            self?.player.enqueueAudio(data)
        },
        onMediaEnded: { [weak self] in
            self?.player.reset()
            self?.isStreaming = false
            self?.pairingDeviceName = nil
        }
    )

    var formattedPairingCode: String {
        guard pairingCode.count == 6 else { return "— — —   — — —" }
        let split = pairingCode.index(pairingCode.startIndex, offsetBy: 3)
        return "\(pairingCode[..<split])  \(pairingCode[split...])"
    }

    var statusSymbol: String {
        if status.contains("Connecting") { return "network" }
        if status.contains("Incorrect") || status.contains("ended") { return "exclamationmark.triangle.fill" }
        return "magnifyingglass"
    }

    var statusColor: Color {
        status.contains("Incorrect") || status.contains("ended") ? .red : .secondary
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        pairingService.start()
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        pairingService.stop()
        player.reset()
    }

    func resetPairing() {
        pairingService.reset()
        player.reset()
        isStreaming = false
        pairingDeviceName = nil
    }
}

#endif
