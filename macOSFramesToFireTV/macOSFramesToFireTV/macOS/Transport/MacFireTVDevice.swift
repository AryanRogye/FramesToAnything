#if os(macOS)
import Foundation
import Network

struct MacFireTVDevice: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let receiverID: String?

    var isRemembered: Bool {
        receiverID.map(TrustedReceiverStore.contains) ?? false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

enum MacFireTVConnectionState: Sendable, Equatable {
    case searching
    case waitingForReceiver
    case connecting(String)
    case authenticating(Bool)
    case connected(String)
    case failed(String)
    case disconnected

    var message: String {
        switch self {
        case .searching: "Searching for Fire TV receivers…"
        case .waitingForReceiver: "Waiting for the Fire TV to connect…"
        case .connecting(let name): "Connecting to \(name)…"
        case .authenticating(let remembered):
            remembered ? "Recognizing this receiver…" : "Checking the pairing code…"
        case .connected(let name): "Securely connected to \(name)"
        case .failed(let message): message
        case .disconnected: "Not connected"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
extension MacFireTVDevice {
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

#endif
