nonisolated enum RemoteMediaCommand: String, Sendable {
    case togglePlayPause = "toggle_play_pause"
    case seekForward10 = "seek_forward_10"
    case seekBackward10 = "seek_backward_10"

    var seekOffset: Double? {
        switch self {
        case .togglePlayPause: nil
        case .seekForward10: 10
        case .seekBackward10: -10
        }
    }
}

nonisolated enum RemoteSeekPolicy {
    /// Missing/invalid duration includes live streams and unseekable players.
    static func target(elapsed: Double?, duration: Double?, offset: Double) -> Double? {
        guard let elapsed, elapsed.isFinite, elapsed >= 0,
              let duration, duration.isFinite, duration > 0,
              offset == 10 || offset == -10 else { return nil }
        return min(duration, max(0, elapsed + offset))
    }
}
