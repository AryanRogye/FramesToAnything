#if os(macOS)
import Foundation
import OSLog
@preconcurrency import MediaRemoteAdapter

/// Now Playing access stays off the network/capture path. Only fixed seek commands
/// reach this bridge; receiver-supplied strings never become process arguments.
@MainActor
final class MacRemoteSeekController {
    static let shared = MacRemoteSeekController()
    private let controller = MediaController()
    private var pending: UUID?

    func seek(command: RemoteMediaCommand, isCurrent: @escaping @Sendable () -> Bool,
              completion: @escaping @Sendable (String) -> Void) {
        guard let offset = command.seekOffset, isCurrent() else { return }
        guard pending == nil else { completion("busy"); return }
        let token = UUID()
        pending = token
        // The adapter's one-shot helper has its own 2 s timeout; this also drops
        // delayed/duplicate callbacks and bounds UI waiting if it fails to answer.
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, self.pending == token else { return }
            pending = nil
            if isCurrent() { completion("unavailable") }
        }
        controller.getTrackInfo { [weak self] info in
            Task { @MainActor in
                guard let self, self.pending == token else { return }
                self.pending = nil
                deadline.cancel()
                guard isCurrent() else { return }
                guard let payload = info?.payload,
                      let target = RemoteSeekPolicy.target(
                        elapsed: payload.currentElapsedTime,
                        duration: payload.durationMicros.map { $0 / 1_000_000 }, offset: offset
                      ) else {
                    completion("unavailable")
                    return
                }
                macTransportLogger.info("Remote seek \(command.rawValue) targetSeconds=\(target)")
                self.controller.setTime(seconds: target)
                completion("sent")
            }
        }
    }
}
#endif
