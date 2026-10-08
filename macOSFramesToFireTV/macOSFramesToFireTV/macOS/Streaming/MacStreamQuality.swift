#if os(macOS)
import Foundation
import SnapCore

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
#endif
