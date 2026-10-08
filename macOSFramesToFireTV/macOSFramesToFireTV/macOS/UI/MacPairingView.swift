#if os(macOS)
import SwiftUI

enum MacPairingWindow {
    static let id = "pair-receiver"
}

struct MacPairingView: View {
    @Bindable var model: MacStreamingModel
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var focusedField: Field?

    private enum Field {
        case code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Pair \(model.selectedReceiverName)", systemImage: "lock.shield")
                    .font(.title2.weight(.semibold))
                Text("Enter the TV’s code, then choose Connect on the TV. You only need to pair once.")
                    .foregroundStyle(.secondary)
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
            focusedField = .code
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


#Preview("Pair Receiver") {
    MacPairingView(model: MacStreamingModel())
}
#endif
