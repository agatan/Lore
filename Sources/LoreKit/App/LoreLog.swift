import OSLog

/// ログ。
///
/// 発話内容・整形結果・語彙は**決してログに出さない**(NFR-2)。
/// ここに出すのは状態遷移・レイテンシ・失敗理由といったメタ情報だけ。
public enum LoreLog {
    static let subsystem = "dev.agatan.Lore"

    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
