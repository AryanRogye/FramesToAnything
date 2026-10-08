import Foundation

nonisolated enum CaptionMode: String, CaseIterable, Identifiable, Sendable {
    case englishCaptions
    case hindiTranslation

    var id: String { rawValue }
    var label: String {
        switch self {
        case .englishCaptions: "English → English Captions"
        case .hindiTranslation: "Hindi → English Translation"
        }
    }
    var modelName: String {
        switch self {
        case .englishCaptions: "base"
        case .hindiTranslation: "small"
        }
    }
    var sourceLanguage: String {
        switch self {
        case .englishCaptions: "en"
        case .hindiTranslation: "hi"
        }
    }
}
