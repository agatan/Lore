/// Lore の配色。`system`はmacOSの外観に従う。
public enum ColorTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "システム設定"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }
}
