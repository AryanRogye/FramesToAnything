#if os(macOS)
import Foundation

nonisolated struct CinemaQualityLevel: Equatable {
    let quality: MacStreamQuality
    let averageBitRate: Int

    init(_ quality: MacStreamQuality, _ averageBitRate: Int) {
        self.quality = quality
        self.averageBitRate = averageBitRate
    }

    static func ladder(maximum: MacStreamQuality) -> [Self] {
        let all: [Self] = [
            .init(.ultraHD, 32_000_000), .init(.ultraHD, 26_000_000),
            .init(.ultraHD, 20_000_000), .init(.quadHD, 18_000_000),
            .init(.quadHD, 14_000_000), .init(.quadHD, 11_000_000),
            .init(.fullHD, 10_000_000), .init(.fullHD, 8_000_000),
            .init(.fullHD, 6_000_000), .init(.hd, 5_000_000),
            .init(.hd, 4_000_000), .init(.hd, 3_000_000),
        ]
        guard let start = all.firstIndex(where: { $0.quality == maximum }) else {
            return Array(all.suffix(6))
        }
        return Array(all[start...])
    }
}
#endif
