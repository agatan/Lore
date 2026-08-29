import Foundation

public enum AccentPalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case ocean
    case mint
    case coral
    case violet

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .ocean: "Ocean"
        case .mint: "Mint"
        case .coral: "Coral"
        case .violet: "Violet"
        }
    }
}
