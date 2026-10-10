/// Queue-owned session state. A generation invalidates all prior-session work.
nonisolated struct ConnectionSessionPolicy: Sendable {
    enum Phase: Sendable { case idle, awaitingHello, authenticating, authenticated }
    private(set) var phase: Phase = .idle
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64? {
        guard phase == .idle else { return nil }
        generation &+= 1
        phase = .awaitingHello
        return generation
    }

    mutating func receivedHello(generation: UInt64) -> Bool {
        guard generation == self.generation, phase == .awaitingHello else { return false }
        phase = .authenticating
        return true
    }

    mutating func authenticated(generation: UInt64) -> Bool {
        guard generation == self.generation, phase == .authenticating else { return false }
        phase = .authenticated
        return true
    }

    static func permitsCode(code: String, target: String?, receiver: String?,
                            expiresAt: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }),
              let target, !target.isEmpty, target == receiver,
              let expiresAt, now < expiresAt else { return false }
        return true
    }

    mutating func end() {
        generation &+= 1
        phase = .idle
    }
}
